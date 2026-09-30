import AppKit
import ApplicationServices
import HistoryCore
import SwiftUI

@main
struct OpenHistoryMenuApp: App {
    @StateObject private var controller = MenuController()

    var body: some Scene {
        MenuBarExtra {
            Text(controller.statusLabel)
            Divider()
            if controller.status.state == .running {
                Button("Pause Computer History") {
                    controller.pause(until: nil)
                }
                Menu("Pause For") {
                    Button("30 Minutes") {
                        controller.pause(
                            until: Date().addingTimeInterval(30 * 60)
                        )
                    }
                    Button("1 Hour") {
                        controller.pause(
                            until: Date().addingTimeInterval(60 * 60)
                        )
                    }
                    Button("Until Tomorrow") {
                        controller.pauseUntilTomorrow()
                    }
                }
            } else {
                Button("Resume Computer History") {
                    controller.resume()
                }
            }
            Divider()
            Button("Clear Last 10 Minutes") {
                controller.confirmClear(.lastTenMinutes)
            }
            Button("Clear All History") {
                controller.confirmClear(.all)
            }
            Divider()
            Button("Show History in Finder") {
                controller.showHistory()
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: controller.iconName)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class MenuController: ObservableObject {
    /// Only republished when the decoded runtime status actually changes, so
    /// the `MenuBarExtra` is not re-rendered while the recorder is idle.
    @Published private(set) var status: RecorderRuntimeStatus

    private let homeURL: URL
    private let controlStore: RuntimeControlStore
    /// Raw bytes of the last `runtime.json` read; identical bytes skip decoding.
    private var lastRuntimeData: Data?
    private var homeWatcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?
    private var fallbackTimer: Timer?
    private var permissionTimer: Timer?
    private var menuObserver: NSObjectProtocol?

    init() {
        if let override = ProcessInfo.processInfo.environment[
            "OPEN_COMPUTER_HISTORY_HOME"
        ], !override.isEmpty {
            homeURL = URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath
            )
        } else {
            homeURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".open-codex-computer-history",
                    isDirectory: true
                )
        }
        controlStore = RuntimeControlStore(homeURL: homeURL)
        status = Self.stoppedStatus(homeURL)
        refresh()
        watchHomeDirectory()
        // Safety net in case a file-system event is missed; the watcher and
        // menu-open refresh keep the icon current in normal operation.
        let fallback = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        fallback.tolerance = 60
        RunLoop.main.add(fallback, forMode: .common)
        fallbackTimer = fallback
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Start the collector even when paused: a paused collector costs
        // almost nothing, and it owns resuming (CLI `resume`, `resumeAt`).
        if status.state == .stopped {
            startCollector()
        }
    }

    /// Starts recording once Accessibility and Input Monitoring are granted.
    /// The menu app requests them itself so System Settings lists this app,
    /// which is also the responsible process for the collector it launches.
    private func startCollector() {
        if CollectorPermissions.isGranted {
            launchCollector()
            return
        }
        CollectorPermissions.request()
        permissionTimer?.invalidate()
        // Polls only until both grants arrive, then invalidates itself.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, CollectorPermissions.isGranted else {
                    return
                }
                timer.invalidate()
                self.permissionTimer = nil
                if self.status.state == .stopped {
                    self.launchCollector()
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    var statusLabel: String {
        switch status.state {
        case .running:
            return "Computer History is running"
        case .paused:
            return "Computer History is paused"
        case .stopped:
            return "Computer History is stopped"
        }
    }

    var iconName: String {
        switch status.state {
        case .running:
            return "clock.arrow.circlepath"
        case .paused:
            return "pause.circle"
        case .stopped:
            return "clock"
        }
    }

    func pause(until resumeAt: Date?) {
        try? controlStore.writeControl(.paused, resumeAt: resumeAt)
        refresh()
    }

    func pauseUntilTomorrow() {
        let resumeAt = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: Date())
        )
        pause(until: resumeAt)
    }

    func resume() {
        try? controlStore.writeControl(.running)
        if status.state == .stopped {
            startCollector()
        }
        refresh()
    }

    func confirmClear(_ scope: HistoryClearScope) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = scopeTitle(scope)
        alert.informativeText =
            "The matching interaction events and generated memories will be deleted. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        _ = try? HistoryMaintenance.clear(homeURL: homeURL, scope: scope)
    }

    func showHistory() {
        try? FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(homeURL)
    }

    /// Re-reads `runtime.json` and publishes only on an actual change.
    private func refresh() {
        let data = try? Data(contentsOf: controlStore.runtimeURL)
        var next: RecorderRuntimeStatus
        if data != nil, data == lastRuntimeData {
            next = status
        } else {
            lastRuntimeData = data
            next = controlStore.readRuntime() ?? Self.stoppedStatus(homeURL)
        }
        // A crashed recorder leaves a stale running/paused record behind.
        if next.state != .stopped,
           let pid = next.processIdentifier,
           kill(pid, 0) != 0,
           errno == ESRCH
        {
            next = Self.stoppedStatus(homeURL)
        }
        if !Self.isSame(next, status) {
            status = next
        }
    }

    private func scheduleRefresh() {
        guard pendingRefresh == nil else {
            return
        }
        // Coalesces the burst of directory events from an atomic rename.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.pendingRefresh = nil
                self.refresh()
            }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Watches the history home directory rather than `runtime.json` itself:
    /// the recorder replaces the file atomically (write + rename), which
    /// changes the directory's entries but would orphan a file descriptor.
    private func watchHomeDirectory() {
        homeWatcher?.cancel()
        homeWatcher = nil
        try? FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let fd = open(homeURL.path, O_EVTONLY)
        guard fd >= 0 else {
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else {
                    return
                }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    // The directory itself moved away; re-arm on the path.
                    self.watchHomeDirectory()
                }
                self.scheduleRefresh()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        homeWatcher = source
        source.resume()
    }

    private static func isSame(
        _ lhs: RecorderRuntimeStatus,
        _ rhs: RecorderRuntimeStatus
    ) -> Bool {
        lhs.state == rhs.state
            && lhs.processIdentifier == rhs.processIdentifier
            && lhs.eventStreamRootPath == rhs.eventStreamRootPath
            && lhs.currentSegmentEventsPath == rhs.currentSegmentEventsPath
            && lhs.currentSegmentMetadataPath == rhs.currentSegmentMetadataPath
            && lhs.suppressedEventsPath == rhs.suppressedEventsPath
            && lhs.startedAt == rhs.startedAt
            && lhs.endedAt == rhs.endedAt
    }

    private func launchCollector() {
        guard let executableURL = Bundle.main.executableURL else {
            return
        }
        let collectorURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("open-history")
        guard FileManager.default.isExecutableFile(atPath: collectorURL.path) else {
            return
        }
        let process = Process()
        process.executableURL = collectorURL
        process.arguments = ["record", "--no-prompt"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "OPEN_COMPUTER_HISTORY_HOME": homeURL.path,
        ]) { _, replacement in replacement }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        try? process.run()
    }

    private func scopeTitle(_ scope: HistoryClearScope) -> String {
        switch scope {
        case .lastTenMinutes:
            return "Clear the last 10 minutes?"
        case .all:
            return "Clear all history?"
        case .today:
            return "Clear today's history?"
        case .applicationSession:
            return "Clear this application session?"
        default:
            return "Clear Computer History?"
        }
    }

    private static func stoppedStatus(_ homeURL: URL) -> RecorderRuntimeStatus {
        RecorderRuntimeStatus(
            state: .stopped,
            processIdentifier: nil,
            eventStreamRootPath: homeURL.path,
            currentSegmentEventsPath: nil,
            currentSegmentMetadataPath: nil,
            suppressedEventsPath: nil,
            startedAt: nil,
            endedAt: nil
        )
    }
}

private enum CollectorPermissions {
    static var isGranted: Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    static func request() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }
}
