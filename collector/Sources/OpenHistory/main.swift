import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import HistoryCore

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let homeURL = historyHome()

switch command {
case "record":
    runRecorder(arguments: Array(arguments.dropFirst()), homeURL: homeURL)
case "sample":
    writeSample(homeURL: homeURL)
case "permissions":
    printPermissions(request: !arguments.contains("--no-prompt"))
case "status":
    printStatus(homeURL: homeURL)
case "pause":
    writePauseControl(arguments: Array(arguments.dropFirst()), homeURL: homeURL)
case "bench":
    runBench(arguments: Array(arguments.dropFirst()))
case "browser-tab":
    printBrowserTab(arguments: Array(arguments.dropFirst()), homeURL: homeURL)
case "page-text":
    printPageText(arguments: Array(arguments.dropFirst()), homeURL: homeURL)
case "resume":
    writeControlState(.running, homeURL: homeURL)
default:
    printUsage()
}

func historyHome() -> URL {
    if let override = ProcessInfo.processInfo.environment["OPEN_COMPUTER_HISTORY_HOME"],
       !override.isEmpty
    {
        return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".open-codex-computer-history", isDirectory: true)
}

func runRecorder(arguments: [String], homeURL: URL) {
    let requestPermissions = !arguments.contains("--no-prompt")
    if requestPermissions {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }

    guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
        fputs(
            "Accessibility and Input Monitoring permissions are required. " +
                "Run `open-history permissions`, then enable the built binary in System Settings.\n",
            stderr
        )
        exit(2)
    }

    do {
        var policy = loadPolicy(homeURL: homeURL)
        if arguments.contains("--capture-text") {
            policy.captureText = true
        }
        let store = try SegmentStore(homeURL: homeURL)
        let recorder = HistoryRecorder(store: store, policy: policy)
        try recorder.start()
        print("Recording interaction events to \(store.eventsURL.path)")
        print("Press Control-C to stop.")

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interruptSource.setEventHandler {
            recorder.stop(reason: "user_interrupt")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        terminateSource.setEventHandler {
            recorder.stop(reason: "terminated")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        interruptSource.resume()
        terminateSource.resume()

        if let duration = optionValue("--duration", in: arguments).flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                recorder.stop(reason: "duration_elapsed")
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        CFRunLoopRun()
        recorder.stop(reason: "run_loop_ended")
    } catch {
        fputs("Recorder failed: \(error)\n", stderr)
        exit(1)
    }
}

func loadPolicy(homeURL: URL) -> ObservationPolicy {
    let configURL = homeURL.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
          let policy = try? JSONDecoder().decode(ObservationPolicy.self, from: data)
    else {
        return ObservationPolicy()
    }
    return policy
}

func writeSample(homeURL: URL) {
    do {
        let store = try SegmentStore(homeURL: homeURL)
        let timestamp = Date()
        let app = EventStreamApp(
            name: "Open History Sample",
            secureInput: false,
            processIdentifier: nil,
            bundleIdentifier: "org.openhistory.sample"
        )
        let window = EventStreamWindow(
            title: "Sample workflow",
            url: nil,
            windowID: nil
        )
        let element = EventStreamAXElement(
            role: "AXTextArea",
            subrole: nil,
            title: "Research notes",
            description: nil,
            value: nil,
            placeholder: nil,
            identifier: "notes"
        )
        try store.append(HistoryEvent(
            id: 1,
            timestamp: timestamp,
            kind: .sessionStarted,
            app: app,
            window: window
        ))
        try store.append(HistoryEvent(
            id: 2,
            timestamp: timestamp,
            kind: .windowChanged,
            app: app,
            window: window,
            ax: EventStreamAXTree(
                mode: .fullTree,
                text: "AXWindow[Sample workflow] > AXTextArea[Research notes]"
            )
        ))
        try store.append(HistoryEvent(
            id: 3,
            timestamp: timestamp,
            kind: .keyboardTextInput,
            app: app,
            window: window,
            keyboard: EventStreamKeyboardInteraction(
                text: nil,
                keyEquivalent: nil,
                modifiers: [],
                target: element
            )
        ))
        try store.finish(reason: "sample")
        print(store.eventsURL.path)
    } catch {
        fputs("Failed to write sample: \(error)\n", stderr)
        exit(1)
    }
}

func printPermissions(request: Bool) {
    if request {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }
    let status = [
        "accessibility": AXIsProcessTrusted(),
        "inputMonitoring": CGPreflightListenEventAccess(),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
       let output = String(data: data, encoding: .utf8)
    {
        print(output)
    }
}

func printStatus(homeURL: URL) {
    let segmentsURL = homeURL.appendingPathComponent("segments", isDirectory: true)
    let segments = (try? FileManager.default.contentsOfDirectory(
        at: segmentsURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []
    let runtime = RuntimeControlStore(homeURL: homeURL).readRuntime()
    let status: [String: Any] = [
        "home": homeURL.path,
        "segments": segments.count,
        "accessibility": AXIsProcessTrusted(),
        "inputMonitoring": CGPreflightListenEventAccess(),
        "state": runtime?.state.rawValue ?? RecorderState.stopped.rawValue,
        "processIdentifier": runtime?.processIdentifier as Any,
        "currentSegmentEventsPath": runtime?.currentSegmentEventsPath as Any,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
       let output = String(data: data, encoding: .utf8)
    {
        print(output)
    }
}

/// Reads the active tab of a running browser through its scripting
/// dictionary, as the recorder does, asking for the Automation permission if
/// it was never decided. Useful to grant or check that permission.
func printBrowserTab(arguments: [String], homeURL: URL) {
    let settings = loadPolicy(homeURL: homeURL).browserScripting
    let application: NSRunningApplication?
    if let bundleIdentifier = arguments.first(where: { !$0.hasPrefix("--") }) {
        application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first
    } else {
        application = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier.flatMap { settings.browser(for: $0) } != nil
        }
    }
    guard let application, let bundleIdentifier = application.bundleIdentifier,
          let browser = settings.browser(for: bundleIdentifier)
    else {
        fputs(
            "No running scriptable browser (or browserScripting is disabled or excludes it).\n",
            stderr
        )
        exit(2)
    }
    let permission = BrowserAppleEvents.permission(
        processIdentifier: application.processIdentifier,
        ask: !arguments.contains("--no-prompt")
    )
    var output: [String: Any] = [
        "bundleIdentifier": bundleIdentifier,
        "permission": permission.string == nil && permission == .value(nil)
            ? "granted"
            : "\(permission)",
    ]
    if case .value = permission {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = BrowserAppleEvents.activeTab(
            processIdentifier: application.processIdentifier,
            browser: browser,
            timeout: max(settings.timeoutMilliseconds, 10) / 1000
        )
        output["milliseconds"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        if case .value = result.outcome {
            output["outcome"] = "ok"
        } else {
            output["outcome"] = "\(result.outcome)"
        }
        output["url"] = result.tab?.url as Any
        output["title"] = result.tab?.title as Any
        output["private"] = result.tab?.isPrivate as Any
    }
    if let data = try? JSONSerialization.data(
        withJSONObject: output,
        options: [.prettyPrinted, .sortedKeys]
    ), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

/// Reads the active tab's text of a browser listed in `pageText` the way the
/// recorder does (Apple Events for the URL, one CDP `Runtime.evaluate`),
/// without the dwell, dedupe, or writing an event. `--port` and `--max`
/// override the configuration for this check.
func printPageText(arguments: [String], homeURL: URL) {
    let policy = loadPolicy(homeURL: homeURL)
    var settings = policy.pageText
    settings.source = .cdp
    if let port = optionValue("--port", in: arguments).flatMap(Int.init) {
        settings.port = port
    }
    if let maximum = optionValue("--max", in: arguments).flatMap(Int.init) {
        settings.maxCharacters = maximum
    }
    let bundleIdentifier = arguments.first(where: { !$0.hasPrefix("--") && Int($0) == nil })
        ?? settings.bundleIdentifiers.first
    guard let bundleIdentifier,
          let application = NSRunningApplication.runningApplications(
              withBundleIdentifier: bundleIdentifier
          ).first,
          let browser = policy.browserScripting.browser(for: bundleIdentifier)
    else {
        fputs("Usage: open-history page-text [BUNDLE-ID] [--port N] [--max N]\n" +
            "The browser must be running and scriptable.\n", stderr)
        exit(2)
    }
    if !settings.bundleIdentifiers.contains(bundleIdentifier) {
        settings.bundleIdentifiers.append(bundleIdentifier)
    }
    let tab = BrowserAppleEvents.activeTab(
        processIdentifier: application.processIdentifier,
        browser: browser,
        timeout: 2
    ).tab
    guard let tab, let pageURL = tab.url else {
        fputs("Could not read the active tab's URL (Automation permission?).\n", stderr)
        exit(1)
    }
    let refusal = PageTextEligibility.refusal(
        settings: settings,
        captureText: policy.captureText,
        bundleIdentifier: bundleIdentifier,
        url: pageURL,
        suppressionReason: policy.shouldSuppress(
            bundleIdentifier: bundleIdentifier,
            windowTitle: tab.title,
            urlDomain: ObservationPolicy.normalizedDomain(pageURL),
            role: nil,
            subrole: nil,
            privateWindow: tab.isPrivate
        ),
        secureInput: false,
        secureEventInput: false
    )
    if let refusal {
        print("{\"refused\": \"\(refusal)\"}")
        return
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let semaphore = DispatchSemaphore(value: 0)
    var output: [String: Any] = ["url": pageURL]
    CDPPageTextReader().read(pageURL: pageURL, title: tab.title, settings: settings) { result in
        output["milliseconds"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        switch result {
        case let .success(page):
            output["element"] = page.element as Any
            output["length"] = page.length
            output["characters"] = page.text.count
            output["preview"] = String(page.text.prefix(200))
        case let .failure(error):
            output["error"] = "\(error)"
        }
        semaphore.signal()
    }
    semaphore.wait()
    if let data = try? JSONSerialization.data(
        withJSONObject: output,
        options: [.prettyPrinted, .sortedKeys]
    ), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func writeControlState(_ state: RecorderState, homeURL: URL) {
    do {
        try RuntimeControlStore(homeURL: homeURL).writeControl(state)
        print(state.rawValue)
    } catch {
        fputs("Failed to update recorder state: \(error)\n", stderr)
        exit(1)
    }
}

func writePauseControl(arguments: [String], homeURL: URL) {
    let resumeAt: Date?
    switch optionValue("--for", in: arguments) {
    case "30m":
        resumeAt = Date().addingTimeInterval(30 * 60)
    case "1h":
        resumeAt = Date().addingTimeInterval(60 * 60)
    case "tomorrow":
        resumeAt = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: Date())
        )
    case nil:
        resumeAt = nil
    default:
        fputs("Pause duration must be 30m, 1h, or tomorrow.\n", stderr)
        exit(2)
    }
    do {
        try RuntimeControlStore(homeURL: homeURL).writeControl(
            .paused,
            resumeAt: resumeAt
        )
        print(RecorderState.paused.rawValue)
    } catch {
        fputs("Failed to pause recorder: \(error)\n", stderr)
        exit(1)
    }
}

func optionValue(_ option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

func printUsage() {
    print("""
    Open Codex Computer History

    Usage:
      open-history record [--duration SECONDS] [--capture-text] [--no-prompt]
      open-history sample
      open-history permissions [--no-prompt]
      open-history status
      open-history browser-tab [BUNDLE-ID] [--no-prompt]
      open-history page-text [BUNDLE-ID] [--port N] [--max N]
      open-history pause [--for 30m|1h|tomorrow]
      open-history resume

    Environment:
      OPEN_COMPUTER_HISTORY_HOME  Override ~/.open-codex-computer-history
    """)
}
