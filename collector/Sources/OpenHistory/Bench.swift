import AppKit
import ApplicationServices
import Darwin
import Foundation
import HistoryCore

/// `open-history bench <bundle-id> [iterations]` measures what the recorder's
/// accessibility work costs a running application, per recorded-event path.
///
/// Every accessibility request is answered on the target's main thread, so
/// the target's CPU time and energy are the numbers that matter. They come
/// from `proc_pid_rusage` summed over every process whose executable lives in
/// the app bundle (Chromium and Electron helpers included), sampled before
/// and after all iterations of a path and reported per iteration. The
/// recorder's own cost (this process) is reported alongside. An idle row
/// gives the target's background noise floor for one second.
func runBench(arguments: [String]) {
    guard let bundleIdentifier = arguments.first,
          let application = NSRunningApplication.runningApplications(
              withBundleIdentifier: bundleIdentifier
          ).first
    else {
        fputs("Usage: open-history bench <bundle-id> [iterations]\n", stderr)
        exit(2)
    }
    let iterations = max(1, arguments.dropFirst().first.flatMap(Int.init) ?? 5)
    let pid = application.processIdentifier
    let bundlePath = application.bundleURL?.path
    let settings = ObservationPolicy().axCapture
    configureAXMessagingTimeout(settings)

    // The recorder requests Chromium/Electron web accessibility on activation;
    // do the same so web content is measured. Chromium builds the tree
    // asynchronously, so give it a moment.
    AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(pid),
        "AXManualAccessibility" as CFString,
        kCFBooleanTrue
    )
    Thread.sleep(forTimeInterval: 2)

    print("per iteration; target = all processes in the app bundle; net = target minus")
    print("the idle row's background rate over the same wall time; self = recorder\n")
    print(String(
        format: "%-28@ %8@ %8@ %6@ %9@ %9@ %8@ %8@ %6@ %8@",
        "path" as NSString, "median" as NSString, "max" as NSString,
        "ax" as NSString, "tgt-cpu" as NSString, "net-cpu" as NSString,
        "tgt-mJ" as NSString, "net-mJ" as NSString, "wakes" as NSString,
        "self-cpu" as NSString
    ))

    var idleCPUPerMillisecond = 0.0
    var idleEnergyPerMillisecond = 0.0

    func measure(_ label: String, idle: Bool = false, _ body: () -> Int) {
        let targets = bundleProcesses(mainPID: pid, bundlePath: bundlePath)
        let targetBefore = ResourceUsage.sum(targets)
        let selfBefore = ResourceUsage.sample(getpid()) ?? ResourceUsage()
        var samples: [Double] = []
        var calls = 0
        for _ in 0..<iterations {
            AXCallCounter.reset()
            let start = DispatchTime.now().uptimeNanoseconds
            _ = body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            calls = AXCallCounter.count
        }
        let target = ResourceUsage.sum(targets).minus(targetBefore)
        let own = (ResourceUsage.sample(getpid()) ?? ResourceUsage()).minus(selfBefore)
        let wall = samples.reduce(0, +)
        if idle, wall > 0 {
            idleCPUPerMillisecond = target.cpuMilliseconds / wall
            idleEnergyPerMillisecond = target.energyMillijoules / wall
        }
        samples.sort()
        let n = Double(iterations)
        print(String(
            format: "%-28@ %5.1f ms %5.1f ms %6d %6.2f ms %6.2f ms %8.2f %8.2f %6.1f %5.2f ms",
            label as NSString,
            samples[samples.count / 2],
            samples.last ?? 0,
            calls,
            target.cpuMilliseconds / n,
            (target.cpuMilliseconds - idleCPUPerMillisecond * wall) / n,
            target.energyMillijoules / n,
            (target.energyMillijoules - idleEnergyPerMillisecond * wall) / n,
            Double(target.wakeups) / n,
            own.cpuMilliseconds / n
        ))
    }

    measure("idle 1 s (noise floor)", idle: true) {
        Thread.sleep(forTimeInterval: 1)
        return 0
    }

    let warmResolver = BrowserURLResolver()
    _ = AccessibilityReader.context(processIdentifier: pid, urlResolver: warmResolver)
    measure("context (keystroke/flush)") {
        AccessibilityReader.context(processIdentifier: pid, urlResolver: warmResolver)?
            .window?.title?.count ?? 0
    }
    measure("context, cold URL cache") {
        AccessibilityReader.context(processIdentifier: pid, urlResolver: BrowserURLResolver())?
            .window?.title?.count ?? 0
    }
    let window = AXAttributeValues(
        AXUIElementCreateApplication(pid),
        [kAXFocusedWindowAttribute as CFString, kAXTitleAttribute as CFString]
    ).element(kAXFocusedWindowAttribute as CFString)
    if ObservationPolicy.browserBundleIdentifiers.contains(bundleIdentifier) {
        measure("browser URL search (cold)") {
            BrowserURLResolver().url(
                window: window,
                windowKey: "bench",
                title: nil,
                bundleIdentifier: bundleIdentifier
            )?.count ?? 0
        }
        let resolver = BrowserURLResolver()
        _ = resolver.url(window: window, windowKey: "bench", title: nil,
                         bundleIdentifier: bundleIdentifier)
        measure("browser URL (cached)") {
            resolver.url(window: window, windowKey: "bench", title: nil,
                         bundleIdentifier: bundleIdentifier)?.count ?? 0
        }
    }
    let focused = AXAttributeValues(
        AXUIElementCreateApplication(pid),
        [kAXFocusedUIElementAttribute as CFString]
    ).element(kAXFocusedUIElementAttribute as CFString)
    measure("selection probe") {
        focused.flatMap { AccessibilityReader.selectedRange(of: $0) }.map { $0.length } ?? 0
    }
    measure("tree capture (window chg)") {
        AccessibilityReader.snapshot(
            processIdentifier: pid,
            settings: settings,
            urlResolver: warmResolver
        )?.axRevision?.lines.count ?? 0
    }
    if let point = focusedWindowCenter(pid) {
        measure("click (context + tree)") {
            AccessibilityReader.snapshot(
                processIdentifier: pid,
                at: point,
                settings: settings,
                urlResolver: warmResolver
            )?.axRevision?.lines.count ?? 0
        }
    }
    if let tree = AccessibilityReader.snapshot(
        processIdentifier: pid,
        settings: settings,
        urlResolver: warmResolver
    )?.axRevision {
        let context = AccessibilityReader.context(processIdentifier: pid, urlResolver: warmResolver)
        print("tree: \(tree.lines.count) lines, \(tree.fullText().utf8.count) bytes; " +
            "url: \(context?.window?.url ?? "-"); " +
            "focused: \(context?.element?.role ?? "-") \(context?.element?.subrole ?? "")")
        if ProcessInfo.processInfo.environment["OPEN_HISTORY_BENCH_DUMP"] != nil {
            print(tree.fullText())
        }
    }
}

private func focusedWindowCenter(_ pid: pid_t) -> CGPoint? {
    let window = AXAttributeValues(
        AXUIElementCreateApplication(pid),
        [kAXFocusedWindowAttribute as CFString]
    ).element(kAXFocusedWindowAttribute as CFString)
    let values = AXAttributeValues(window, [
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
    ])
    guard let position = values.raw(kAXPositionAttribute as CFString),
          let size = values.raw(kAXSizeAttribute as CFString)
    else {
        return nil
    }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent)
    else {
        return nil
    }
    return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
}

/// The app's main process plus every process whose executable is inside the
/// app bundle (browser and Electron helpers, renderers, GPU process).
private func bundleProcesses(mainPID: pid_t, bundlePath: String?) -> [pid_t] {
    guard let bundlePath else {
        return [mainPID]
    }
    let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
    let capacity = proc_listallpids(nil, 0) + 64
    var pids = [pid_t](repeating: 0, count: Int(max(capacity, 64)))
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var result: Set<pid_t> = [mainPID]
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for candidate in pids.prefix(Int(max(count, 0))) where candidate > 0 {
        guard proc_pidpath(candidate, &buffer, UInt32(buffer.count)) > 0 else {
            continue
        }
        if String(cString: buffer).hasPrefix(prefix) {
            result.insert(candidate)
        }
    }
    return Array(result)
}

struct ResourceUsage {
    var cpuTicks: UInt64 = 0
    var energyNanojoules: UInt64 = 0
    var wakeups: UInt64 = 0

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    var cpuMilliseconds: Double {
        Double(cpuTicks) * Double(Self.timebase.numer) / Double(Self.timebase.denom) / 1e6
    }

    var energyMillijoules: Double {
        Double(energyNanojoules) / 1e6
    }

    static func sample(_ pid: pid_t) -> ResourceUsage? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else {
            return nil
        }
        return ResourceUsage(
            cpuTicks: info.ri_user_time + info.ri_system_time,
            energyNanojoules: info.ri_energy_nj > 0 ? info.ri_energy_nj : info.ri_billed_energy,
            wakeups: info.ri_interrupt_wkups + info.ri_pkg_idle_wkups
        )
    }

    static func sum(_ pids: [pid_t]) -> [pid_t: ResourceUsage] {
        var result: [pid_t: ResourceUsage] = [:]
        for pid in pids {
            result[pid] = sample(pid)
        }
        return result
    }

    func minus(_ other: ResourceUsage) -> ResourceUsage {
        ResourceUsage(
            cpuTicks: cpuTicks &- other.cpuTicks,
            energyNanojoules: energyNanojoules &- other.energyNanojoules,
            wakeups: wakeups &- other.wakeups
        )
    }
}

private extension Dictionary where Key == pid_t, Value == ResourceUsage {
    /// Sums the change per process present in both samples.
    func minus(_ before: [pid_t: ResourceUsage]) -> ResourceUsage {
        var total = ResourceUsage()
        for (pid, after) in self {
            guard let previous = before[pid],
                  after.cpuTicks >= previous.cpuTicks
            else {
                continue
            }
            let delta = after.minus(previous)
            total.cpuTicks += delta.cpuTicks
            total.energyNanojoules += delta.energyNanojoules
            total.wakeups += delta.wakeups
        }
        return total
    }
}
