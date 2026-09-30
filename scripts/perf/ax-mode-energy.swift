// Measures the CPU / energy / wakeup / memory cost of Chromium & Electron
// accessibility ("AX") mode for one running app, by alternating the mode
// off/on in equal windows and summing proc_pid_rusage over every process of
// the app (main + GPU/utility helpers + renderers).
//
// Build & run through scripts/perf/ax-mode-energy.sh. Direct use:
//   swiftc -O ax-mode-energy.swift -o /tmp/ax-mode-energy
//   /tmp/ax-mode-energy --bundle com.anthropic.claudefordesktop --windows 4 --seconds 60
//
// Options:
//   --bundle ID | --pid PID  target app (first running instance of the bundle)
//   --windows N              off/on pairs (default 4 -> off,on,off,on,...)
//   --seconds S              length of each window (default 60)
//   --interval I             sampling interval inside a window (default 10)
//   --attrs manual,eui       attributes toggled on the app element
//                            (manual = AXManualAccessibility, eui = AXEnhancedUserInterface)
//   --settle S               seconds to wait after a toggle before measuring (default 0;
//                            Chromium applies "on" after a 2 s debounce, so 0 includes
//                            the tree-build cost of every transition)
//   --probe                  after each window, count AXWebArea descendants (bounded walk)
//                            to verify that the toggle really changed the web AX tree
//
// Energy is ri_energy_nj (the task's own CPU energy estimate). ri_billed_energy
// is also reported but only covers energy billed via vouchers and stays near 0
// for renderers. AX mode is always set to off (false) on exit, including
// SIGINT/SIGTERM. Reading the attributes back is NOT a reliable state check:
// Electron returns true only when the mode equals kAXModeComplete exactly, and
// Chromium browsers do not implement a getter at all -- use --probe instead.

import AppKit
import ApplicationServices
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Arguments

var bundleID: String?
var targetPID: pid_t?
var windows = 4
var seconds = 60.0
var interval = 10.0
var settle = 0.0
var attrs = ["AXManualAccessibility", "AXEnhancedUserInterface"]
var probe = false
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--bundle": bundleID = it.next()
        case "--pid": targetPID = pid_t(Int32(it.next() ?? "") ?? -1)
        case "--windows": windows = Int(it.next() ?? "") ?? windows
        case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
        case "--interval": interval = Double(it.next() ?? "") ?? interval
        case "--settle": settle = Double(it.next() ?? "") ?? settle
        case "--probe": probe = true
        case "--attrs":
            attrs = (it.next() ?? "").split(separator: ",").map {
                $0 == "manual" ? "AXManualAccessibility" : $0 == "eui" ? "AXEnhancedUserInterface" : String($0)
            }
        default:
            FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
}
guard AXIsProcessTrusted() else {
    print("error: this process needs Accessibility permission (run from a trusted terminal)")
    exit(1)
}
let mainPID: pid_t = {
    if let p = targetPID { return p }
    if let b = bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
        return app.processIdentifier
    }
    print("error: target app not running (\(bundleID ?? "no --bundle/--pid"))")
    exit(1)
}()
let appName = NSRunningApplication(processIdentifier: mainPID)?.localizedName ?? "pid \(mainPID)"
let appElement = AXUIElementCreateApplication(mainPID)
AXUIElementSetMessagingTimeout(appElement, 2)

// MARK: - AX toggling

func setAX(_ on: Bool) -> String {
    attrs.map { a in
        let r = AXUIElementSetAttributeValue(appElement, a as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
        return "\(a)=\(on) -> \(r.rawValue)"
    }.joined(separator: ", ")
}
func restoreOff() { _ = setAX(false) }
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        restoreOff()
        print("\ninterrupted: AX mode set to off")
        exit(130)
    }
}

func axAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
/// Counts AX nodes under AXWebArea elements. Never reads AXRole of the
/// application element itself: in Chromium/Electron that latches basic AX
/// mode for the life of the process.
func probeWebNodes() -> Int {
    var nodes = 0, visited = 0
    func walk(_ e: AXUIElement, inWeb: Bool, depth: Int) {
        if visited > 50_000 || depth > 80 { return }
        visited += 1
        let web = inWeb || (axAttr(e, "AXRole") as? String) == "AXWebArea"
        if web { nodes += 1 }
        for c in (axAttr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, inWeb: web, depth: depth + 1) }
    }
    for w in (axAttr(appElement, "AXWindows") as? [AXUIElement]) ?? [] { walk(w, inWeb: false, depth: 0) }
    return nodes
}

// MARK: - Process tree and rusage

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let nsPerTick = Double(timebase.numer) / Double(timebase.denom)

func allPIDs() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var buf = [pid_t](repeating: 0, count: Int(n) * 2)
    let c = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return Array(buf.prefix(Int(max(c, 0))))
}
func parent(_ p: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let r = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return r > 0 ? pid_t(info.pbi_ppid) : -1
}
func path(_ p: pid_t) -> String {
    var b = [CChar](repeating: 0, count: 4096)
    proc_pidpath(p, &b, 4096)
    return String(cString: b)
}
/// main + direct children that live inside the same .app bundle (skips e.g.
/// CLI tools or native-messaging hosts the app spawned from elsewhere).
func appProcesses() -> [pid_t: String] {
    let mainPath = path(mainPID)
    let bundleRoot = mainPath.components(separatedBy: ".app/").first.map { $0 + ".app/" } ?? mainPath
    var out: [pid_t: String] = [mainPID: "main"]
    for p in allPIDs() where p != mainPID && parent(p) == mainPID {
        let pa = path(p)
        guard pa.hasPrefix(bundleRoot) else { continue }
        if pa.contains("(Renderer)") { out[p] = "renderer" }
        else if pa.contains("(GPU)") || pa.contains("Helper.app/") || pa.contains("Helper (Plugin)") { out[p] = "gpu+util" }
        else { out[p] = "other" }
    }
    return out
}
struct Usage { var energy: UInt64 = 0, billed: UInt64 = 0, cpu: UInt64 = 0, wakeups: UInt64 = 0, footprint: UInt64 = 0 }
func usage(_ p: pid_t) -> Usage? {
    var ri = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V6, $0) }
    }
    guard r == 0 else { return nil }
    return Usage(energy: ri.ri_energy_nj, billed: ri.ri_billed_energy,
                 cpu: ri.ri_user_time + ri.ri_system_time,
                 wakeups: ri.ri_pkg_idle_wkups + ri.ri_interrupt_wkups,
                 footprint: ri.ri_phys_footprint)
}
struct Totals { var energyJ = 0.0, billedJ = 0.0, cpuS = 0.0, wakeups = 0.0, footprintMB = 0.0, procs = 0 }

/// Samples every `interval` for `duration`, summing per-interval deltas so
/// processes that start or exit mid-window are still counted.
func measure(_ duration: Double) -> [String: Totals] {
    func snapshot() -> [pid_t: (String, Usage)] {
        var d: [pid_t: (String, Usage)] = [:]
        for (p, g) in appProcesses() { if let u = usage(p) { d[p] = (g, u) } }
        return d
    }
    var acc: [String: Totals] = [:]
    var prev = snapshot()
    let start = Date()
    while Date().timeIntervalSince(start) < duration - 0.01 {
        Thread.sleep(forTimeInterval: min(interval, duration - Date().timeIntervalSince(start)))
        let cur = snapshot()
        for (p, (g, u)) in cur {
            let b = prev[p]?.1 ?? Usage()
            var t = acc[g] ?? Totals()
            t.energyJ += Double(u.energy &- b.energy) / 1e9
            t.billedJ += Double(u.billed &- b.billed) / 1e9
            t.cpuS += Double(u.cpu &- b.cpu) * nsPerTick / 1e9
            t.wakeups += Double(u.wakeups &- b.wakeups)
            acc[g] = t
        }
        prev = cur
    }
    for (_, (g, u)) in prev {
        var t = acc[g] ?? Totals()
        t.footprintMB += Double(u.footprint) / 1_048_576
        t.procs += 1
        acc[g] = t
    }
    var total = Totals()
    for t in acc.values {
        total.energyJ += t.energyJ; total.billedJ += t.billedJ; total.cpuS += t.cpuS
        total.wakeups += t.wakeups; total.footprintMB += t.footprintMB; total.procs += t.procs
    }
    acc["TOTAL"] = total
    return acc
}

// MARK: - Run

print("target: \(appName) pid \(mainPID); attrs: \(attrs.joined(separator: ",")); \(windows)x(off,on) windows of \(Int(seconds))s")
var results: [String: [Totals]] = [:]  // key "group|mode"
for round in 1...windows {
    for on in [false, true] {
        let mode = on ? "on" : "off"
        let setResult = setAX(on)
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let r = measure(seconds)
        for (g, t) in r { results["\(g)|\(mode)", default: []].append(t) }
        let tot = r["TOTAL"]!
        var line = String(format: "round %d %-3@ energy %.2f J  cpu %.2f%%  wakeups %.0f/s  frontmost=%@",
                          round, mode as NSString, tot.energyJ, tot.cpuS / seconds * 100,
                          tot.wakeups / seconds, front as NSString)
        if probe { line += "  webAXNodes=\(probeWebNodes())" }
        if round == 1 { line += "  [\(setResult)]" }
        print(line)
    }
}
restoreOff()

func stat(_ xs: [Double]) -> String {
    let s = xs.sorted()
    let med = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    return String(format: "%8.2f [%.2f-%.2f]", med, s.first ?? 0, s.last ?? 0)
}
print("\nper \(Int(seconds))s window: median [min-max] over \(windows) windows")
print("group     mode  energy_J                  billed_J  cpu_%                     wakeups/s  footprint_MB  procs")
let groups = Set(results.keys.map { String($0.split(separator: "|")[0]) }).sorted { $0 == "TOTAL" ? false : $1 == "TOTAL" ? true : $0 < $1 }
for g in groups {
    for mode in ["off", "on"] {
        guard let r = results["\(g)|\(mode)"], !r.isEmpty else { continue }
        let med = { (xs: [Double]) -> Double in xs.sorted()[xs.count / 2] }
        print(String(format: "%-9@ %-4@ %@ %9.2f %@ %10.1f %13.0f %6d",
                     g as NSString, mode as NSString,
                     stat(r.map(\.energyJ)) as NSString,
                     med(r.map(\.billedJ)),
                     stat(r.map { $0.cpuS / seconds * 100 }) as NSString,
                     med(r.map { $0.wakeups / seconds }),
                     med(r.map(\.footprintMB)),
                     r.last!.procs))
    }
}
if let off = results["TOTAL|off"], let on = results["TOTAL|on"] {
    let m = { (xs: [Double]) -> Double in let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
    let dE = m(on.map(\.energyJ)) - m(off.map(\.energyJ))
    print(String(format: "\nTOTAL on-off: %+.2f J per %.0fs window = %+.1f mW average", dE, seconds, dE / seconds * 1000))
}
print("AX mode restored to off (\(attrs.joined(separator: ", ")) = false)")
