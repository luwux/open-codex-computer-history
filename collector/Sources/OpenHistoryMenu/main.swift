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
    @Published var status: RecorderRuntimeStatus

    private let homeURL: URL
    private let controlStore: RuntimeControlStore
    private var timer: Timer?
    private var permissionTimer: Timer?

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
        status = controlStore.readRuntime() ?? Self.stoppedStatus(homeURL)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if status.state == .stopped,
           controlStore.readControl()?.state != .paused
        {
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
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] timer in
            Task { @MainActor in
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

    private func refresh() {
        status = controlStore.readRuntime() ?? Self.stoppedStatus(homeURL)
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
