import CoreServices
import Foundation
import HistoryCore

/// Raw Apple Events for `get <property> of active tab of window 1`.
///
/// Built from four-character codes rather than compiled AppleScript: no
/// script compilation, no dictionary lookup that could launch an app, an
/// explicit timeout per event, and usable from any thread. Events go to the
/// process ID, so a browser that is not running is never launched.
enum BrowserAppleEvents {
    static func activeTab(
        processIdentifier: pid_t,
        browser: ScriptableBrowser,
        timeout: TimeInterval
    ) -> (tab: BrowserTab?, outcome: AppleEventOutcome) {
        let window = objectSpecifier(
            want: browser.windowClass,
            from: .null(),
            form: fourCharCode("indx"),
            data: NSAppleEventDescriptor(int32: 1)
        )
        let tab = property(browser.activeTabProperty, of: window)
        let url = get(
            property(browser.urlProperty, of: tab),
            processIdentifier: processIdentifier,
            timeout: timeout
        )
        guard case let .value(rawURL) = url else {
            return (nil, url)
        }
        let title = get(
            property(browser.titleProperty, of: tab),
            processIdentifier: processIdentifier,
            timeout: timeout
        ).string
        let mode = browser.modeProperty.flatMap {
            get(
                property($0, of: window),
                processIdentifier: processIdentifier,
                timeout: timeout
            ).string
        }
        return (BrowserTab(rawURL: rawURL, rawTitle: title, mode: mode), url)
    }

    /// Whether this process may send Apple Events to the browser. With
    /// `ask`, macOS shows its Automation prompt if the user never decided;
    /// that blocks until answered, so call it off the main thread. The
    /// target is the process: addressing some browsers by bundle identifier
    /// made this call hang (observed with Dia), by process it answers in
    /// tens of milliseconds.
    static func permission(processIdentifier: pid_t, ask: Bool) -> AppleEventOutcome {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        guard let address = target.aeDesc else {
            return .failed(-1)
        }
        let status = AEDeterminePermissionToAutomateTarget(
            address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            ask
        )
        return AppleEventOutcome(status: Int(status))
    }

    private static func get(
        _ specifier: NSAppleEventDescriptor,
        processIdentifier: pid_t,
        timeout: TimeInterval
    ) -> AppleEventOutcome {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCharCode("core"),
            eventID: fourCharCode("getd"),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(specifier, forKeyword: fourCharCode("----"))
        do {
            let reply = try event.sendEvent(
                options: [.waitForReply, .neverInteract],
                timeout: timeout
            )
            return AppleEventOutcome(reply: reply)
        } catch let error as NSError {
            return AppleEventOutcome(status: error.code)
        }
    }

    private static func property(
        _ code: FourCharCode,
        of container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        objectSpecifier(
            want: fourCharCode("prop"),
            from: container,
            form: fourCharCode("prop"),
            data: NSAppleEventDescriptor(typeCode: code)
        )
    }

    private static func objectSpecifier(
        want: FourCharCode,
        from container: NSAppleEventDescriptor,
        form: FourCharCode,
        data: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: fourCharCode("want"))
        record.setDescriptor(container, forKeyword: fourCharCode("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: fourCharCode("form"))
        record.setDescriptor(data, forKeyword: fourCharCode("seld"))
        return record.coerce(toDescriptorType: fourCharCode("obj ")) ?? record
    }
}

/// Resolves the frontmost browser tab's URL and title through Apple Events,
/// cached per window and title so events go out only when a window becomes
/// frontmost, its title changes, or the cached value is older than
/// `refreshSeconds` — never per keystroke.
///
/// Automation permission is decided off the main thread. macOS prompts at
/// most once per browser per recorder run; after a denial the recorder
/// re-checks silently every ten minutes (so enabling it in System Settings
/// takes effect) and meanwhile uses the accessibility fallback.
final class BrowserScriptingResolver {
    private enum Access {
        case unknown
        case checking
        case granted
        case denied(Date)
    }

    private struct Entry {
        let title: String?
        let tab: BrowserTab
        let at: Date
    }

    var settings: BrowserScriptingSettings
    private var access: [String: Access] = [:]
    private var prompted = Set<String>()
    private var pausedUntil: [String: Date] = [:]
    private var entries: [String: Entry] = [:]
    private let permissionQueue = DispatchQueue(
        label: "open-history.browser-scripting",
        qos: .utility
    )
    private static let deniedRecheckInterval: TimeInterval = 600
    private static let timeoutPause: TimeInterval = 60
    private static let failurePause: TimeInterval = 10

    init(settings: BrowserScriptingSettings) {
        self.settings = settings
    }

    /// Main thread only.
    func tab(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        windowKey: String?,
        title: String?,
        now: Date = Date()
    ) -> BrowserTab? {
        guard let bundleIdentifier,
              let browser = settings.browser(for: bundleIdentifier)
        else {
            return nil
        }
        let key = windowKey ?? "pid:\(processIdentifier)"
        let cached = entries[key].flatMap { $0.title == title ? $0 : nil }
        if let cached, now.timeIntervalSince(cached.at) < settings.refreshSeconds {
            return cached.tab
        }
        guard isAllowed(bundleIdentifier, processIdentifier: processIdentifier, now: now) else {
            return cached?.tab
        }
        let result = BrowserAppleEvents.activeTab(
            processIdentifier: processIdentifier,
            browser: browser,
            timeout: max(settings.timeoutMilliseconds, 10) / 1000
        )
        switch result.outcome {
        case .value:
            guard let tab = result.tab else {
                return nil
            }
            if entries.count > 64 {
                entries.removeAll()
            }
            entries[key] = Entry(title: title, tab: tab, at: now)
            return tab
        case .notPermitted:
            access[bundleIdentifier] = .denied(now)
        case .needsConsent:
            access[bundleIdentifier] = .unknown
        case .timedOut:
            pausedUntil[bundleIdentifier] = now.addingTimeInterval(Self.timeoutPause)
        case .unavailable, .failed:
            pausedUntil[bundleIdentifier] = now.addingTimeInterval(Self.failurePause)
        }
        return cached?.tab
    }

    private func isAllowed(
        _ bundleIdentifier: String,
        processIdentifier: pid_t,
        now: Date
    ) -> Bool {
        if let until = pausedUntil[bundleIdentifier], until > now {
            return false
        }
        switch access[bundleIdentifier] ?? .unknown {
        case .granted:
            return true
        case .checking:
            return false
        case .unknown:
            checkAccess(
                bundleIdentifier,
                processIdentifier: processIdentifier,
                ask: !prompted.contains(bundleIdentifier)
            )
            return false
        case let .denied(since):
            if now.timeIntervalSince(since) >= Self.deniedRecheckInterval {
                checkAccess(bundleIdentifier, processIdentifier: processIdentifier, ask: false)
            }
            return false
        }
    }

    private func checkAccess(_ bundleIdentifier: String, processIdentifier: pid_t, ask: Bool) {
        access[bundleIdentifier] = .checking
        if ask {
            prompted.insert(bundleIdentifier)
        }
        permissionQueue.async { [weak self] in
            let outcome = BrowserAppleEvents.permission(
                processIdentifier: processIdentifier,
                ask: ask
            )
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch outcome {
                case .value:
                    self.access[bundleIdentifier] = .granted
                case .unavailable:
                    // The browser quit before the check; decide next time.
                    self.access[bundleIdentifier] = .unknown
                default:
                    // Denied, still undecided after the one prompt, or an
                    // error: stay on the fallback and re-check silently.
                    self.access[bundleIdentifier] = .denied(Date())
                }
            }
        }
    }
}
