import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HistoryCore

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let recorder = Unmanaged<HistoryRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handleEventTap(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private let accessibilityCallback: AXObserverCallback = { _, element, notification, userInfo in
    guard let userInfo else {
        return
    }
    let recorder = Unmanaged<HistoryRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handleAccessibilityNotification(notification as String, element: element)
}

/// Records interaction events from the event tap and accessibility
/// notifications.
///
/// Accessibility requests are answered on the target application's main
/// thread, so each event pays only for what it writes: typing reads the
/// focused element once per burst, trees are captured only for event kinds
/// that carry them (and at most every `minimumTreeIntervalSeconds` per
/// unchanged window), and notifications that cannot produce an event cost no
/// requests. While paused the event tap, accessibility observer, and media
/// polling are off.
final class HistoryRecorder {
    private struct MouseDownState {
        let point: CGPoint
        let button: String
        let clickCount: Int
        let modifiers: [String]
        let processIdentifier: pid_t?
        let originElement: AXUIElement?
    }

    private var store: SegmentStore
    private let runtimeControl: RuntimeControlStore
    private let recorderStartedAt: Date
    private let segmentDurationSeconds: TimeInterval
    private var policy: ObservationPolicy
    private var sequence = 0
    private var currentProcessIdentifier: pid_t?
    private var workspaceObserver: NSObjectProtocol?
    private var presenceObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var webAccessibilityProcesses = Set<pid_t>()
    private var mediaTimer: Timer?
    private var mediaOwners: [String: MediaPlaybackOwner] = [:]
    private var accessibilityObserver: AXObserver?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var mouseDown: MouseDownState?
    private var textBuffer = ""
    private var textFlushTask: DispatchWorkItem?
    /// Focused-element context for the current typing burst; decides secure
    /// input per keystroke without a request. Cleared whenever focus may move.
    private var focusContext: AccessibilitySnapshot?
    private var terminalChanged = false
    private var terminalFlushTask: DispatchWorkItem?
    private var axDebounceTasks: [String: DispatchWorkItem] = [:]
    private var lastWindowSignature: String?
    private var lastWindowElement: AXUIElement?
    private var windowRetryTask: DispatchWorkItem?
    private var windowRetryCount = 0
    private var lastSelectionSignature: String?
    private var previousAXRevisionByWindowKey: [String: AXTreeRevisionSnapshot] = [:]
    private var latestURLByWindowKey: [String: String] = [:]
    private var captureThrottle: AXCaptureThrottle
    private let urlResolver = BrowserURLResolver()
    private let browserScripting: BrowserScriptingResolver
    private let pageTextReader = CDPPageTextReader()
    private var pageTextTracker: PageTextDwellTracker
    private var pageTextSnapshot: AccessibilitySnapshot?
    private var pageTextTask: DispatchWorkItem?
    private var pageTextInFlight = false
    private var controlWatcher: DispatchSourceFileSystemObject?
    private var controlCheckTask: DispatchWorkItem?
    private var controlFallbackTimer: Timer?
    private var resumeTimer: Timer?
    private var segmentTimer: Timer?
    private var recorderState: RecorderState = .running
    private var stopped = false

    init(store: SegmentStore, policy: ObservationPolicy) {
        self.store = store
        self.runtimeControl = RuntimeControlStore(homeURL: store.homeURL)
        self.recorderStartedAt = store.startedAt
        self.segmentDurationSeconds = ProcessInfo.processInfo.environment[
            "OPEN_HISTORY_SEGMENT_SECONDS"
        ].flatMap(Double.init) ?? 600
        self.policy = policy
        self.browserScripting = BrowserScriptingResolver(settings: policy.browserScripting)
        self.pageTextTracker = PageTextDwellTracker(
            dwellSeconds: policy.pageText.effectiveDwellSeconds,
            recaptureSeconds: policy.pageText.effectiveRecaptureSeconds
        )
        self.captureThrottle = AXCaptureThrottle(
            minimumInterval: policy.axCapture.minimumTreeIntervalSeconds
        )
    }

    func start() throws {
        configureAXMessagingTimeout(policy.axCapture)
        if policy.retentionHours > 0 {
            SegmentStore.prune(
                homeURL: store.homeURL,
                olderThan: policy.retentionHours * 60 * 60
            )
        }
        if runtimeControl.readControl()?.state == .paused {
            recorderState = .paused
        }
        observeWorkspace()
        installEventTap()
        currentProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if recorderState == .running {
            startObservingFrontmostApplication()
            try append(kind: .sessionStarted, snapshot: contextSnapshot())
            refreshWindow()
        } else {
            try append(kind: .sessionStarted, snapshot: nil)
            suspendObservation()
        }
        try writeRuntimeStatus(state: recorderState)
        watchControl()
        reconcileControlState()

        let segmentTimer = Timer.scheduledTimer(
            withTimeInterval: segmentDurationSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.rotateSegment()
        }
        segmentTimer.tolerance = min(60, segmentDurationSeconds / 10)
        self.segmentTimer = segmentTimer
    }

    func stop(reason: String) {
        guard !stopped else {
            return
        }
        flushTextBuffer()
        flushTerminalBuffer()
        stopped = true
        controlWatcher?.cancel()
        controlWatcher = nil
        controlCheckTask?.cancel()
        controlFallbackTimer?.invalidate()
        controlFallbackTimer = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        axDebounceTasks.values.forEach { $0.cancel() }
        axDebounceTasks.removeAll()
        windowRetryTask?.cancel()
        windowRetryTask = nil
        cancelPageText()
        try? append(
            kind: .sessionEnded,
            snapshot: recorderState == .running ? contextSnapshot() : nil
        )
        try? store.finish(reason: reason)
        try? writeRuntimeStatus(state: .stopped, endedAt: Date())

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        mediaTimer?.invalidate()
        mediaTimer = nil
        for (center, observer) in presenceObservers {
            center.removeObserver(observer)
        }
        presenceObservers.removeAll()
        removeAccessibilityObserver()
        releaseWebAccessibility()
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    // MARK: - Event tap

    func handleEventTap(type: CGEventType, event: CGEvent) {
        guard !stopped, recorderState == .running else {
            return
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        switch type {
        case .keyDown:
            handleKeyDown(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Only the element under the pointer is read now (one request);
            // it becomes the drag origin if the pointer moves before release.
            let processIdentifier = currentProcessIdentifier
            mouseDown = MouseDownState(
                point: event.location,
                button: mouseButton(for: type),
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                modifiers: modifierNames(event.flags),
                processIdentifier: processIdentifier,
                originElement: processIdentifier.flatMap {
                    AccessibilityReader.elementAtPosition(
                        AXUIElementCreateApplication($0),
                        point: event.location
                    )
                }
            )
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            handleMouseUp(event: event)
        default:
            break
        }
    }

    private func installEventTap() {
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: RecorderEventTap.mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let eventTap else {
            return
        }
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), eventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handleKeyDown(_ event: CGEvent) {
        let flags = event.flags
        let modifiers = modifierNames(flags)
        let key = keyEquivalent(event)
        let hasShortcutModifier = flags.contains(.maskCommand) ||
            flags.contains(.maskControl) ||
            flags.contains(.maskAlternate)

        if hasShortcutModifier {
            let context = flushTextBuffer()
            focusContext = nil
            let snapshot = eventSnapshot(kind: .keyboardShortcut, context: context)
            try? append(
                kind: .keyboardShortcut,
                snapshot: snapshot,
                keyboard: EventStreamKeyboardInteraction(
                    text: nil,
                    keyEquivalent: key,
                    modifiers: modifiers,
                    target: snapshot?.element
                )
            )
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 36 || keyCode == 76 {
            let context = flushTextBuffer()
            focusContext = nil
            let snapshot = eventSnapshot(kind: .keyboardSubmit, context: context)
            try? append(
                kind: .keyboardSubmit,
                snapshot: snapshot,
                keyboard: EventStreamKeyboardInteraction(
                    text: nil,
                    keyEquivalent: "return",
                    modifiers: modifiers,
                    target: snapshot?.element
                )
            )
            let focusedElement = snapshot?.focusedElement
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                [weak self] in
                self?.checkSelection(of: focusedElement)
            }
            return
        }

        let characters = NSEvent(cgEvent: event)?.characters ?? ""
        guard !characters.isEmpty else {
            return
        }
        // One context read per burst (or after focus may have moved) decides
        // secure input; the event's snapshot is read once when it flushes.
        if focusContext == nil {
            focusContext = contextSnapshot()
        }
        if policy.captureText, focusContext?.app.secureInput != true {
            if textBuffer == "\u{0}" {
                textBuffer = ""
            }
            textBuffer.append(characters)
        } else if textBuffer.isEmpty {
            // An empty sentinel keeps a metadata-only typing burst observable.
            textBuffer = "\u{0}"
        }
        if keyCode == 48 {
            // Tab moves focus; the next keystroke re-reads it.
            focusContext = nil
        }
        scheduleTextFlush()
    }

    private func scheduleTextFlush() {
        textFlushTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.flushTextBuffer()
        }
        textFlushTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: task)
    }

    /// Writes the pending typing burst. Returns the context it read, so a
    /// shortcut or submit at the same moment can reuse it.
    @discardableResult
    private func flushTextBuffer() -> AccessibilitySnapshot? {
        textFlushTask?.cancel()
        textFlushTask = nil
        guard !textBuffer.isEmpty else {
            return nil
        }
        var snapshot = contextSnapshot()
        if let current = snapshot, current.element == nil,
           let burst = focusContext, burst.processIdentifier == current.processIdentifier
        {
            // Focus can be momentarily unavailable after typing (input
            // methods, re-rendering web views); keep the burst's target.
            snapshot = current.replacingElement(burst.element)
        }
        let text = textBuffer == "\u{0}" ? nil : textBuffer
        textBuffer = ""
        try? append(
            kind: .keyboardTextInput,
            snapshot: snapshot,
            keyboard: EventStreamKeyboardInteraction(
                text: text,
                keyEquivalent: nil,
                modifiers: [],
                target: snapshot?.element
            )
        )
        return snapshot
    }

    private func handleMouseUp(event: CGEvent) {
        guard let down = mouseDown else {
            return
        }
        mouseDown = nil
        focusContext = nil
        let distance = hypot(event.location.x - down.point.x, event.location.y - down.point.y)
        let kind: HistoryEventKind = distance > 6
            ? .mouseDrag
            : down.button == "right" ? .mouseContextMenu : .mouseClick
        let destinationSnapshot = eventSnapshot(kind: kind, at: event.location)
        let mouse: EventStreamMouseInteraction
        if kind == .mouseDrag {
            mouse = EventStreamMouseInteraction(
                button: down.button,
                clickCount: down.clickCount,
                modifiers: down.modifiers,
                target: nil,
                origin: dragOrigin(down, destination: destinationSnapshot),
                destination: destinationSnapshot?.dragEndpoint
            )
        } else {
            mouse = EventStreamMouseInteraction(
                button: down.button,
                clickCount: down.clickCount,
                modifiers: down.modifiers,
                target: minimalMouseTarget(destinationSnapshot?.element),
                origin: nil,
                destination: nil
            )
        }
        try? append(kind: kind, snapshot: destinationSnapshot, mouse: mouse)
    }

    private func dragOrigin(
        _ down: MouseDownState,
        destination: AccessibilitySnapshot?
    ) -> EventStreamMouseDragEndpoint? {
        let base: AccessibilitySnapshot?
        if let destination, destination.processIdentifier == down.processIdentifier {
            base = destination
        } else {
            base = down.processIdentifier.flatMap {
                AccessibilityReader.context(
                    processIdentifier: $0,
                    urlResolver: urlResolver,
                    browserScripting: browserScripting
                )
            }
        }
        guard let base else {
            return nil
        }
        guard let originElement = down.originElement else {
            return base.replacingElement(nil).dragEndpoint
        }
        let element = AccessibilityReader.eventElement(originElement, includeValue: true)
        let secure = ObservationPolicy.isSecureRole(element.role, subrole: element.subrole)
        return EventStreamMouseDragEndpoint(
            app: EventStreamApp(
                name: base.app.name,
                secureInput: secure,
                processIdentifier: nil,
                bundleIdentifier: base.app.bundleIdentifier
            ),
            window: base.window,
            element: secure
                ? EventStreamAXElement(
                    role: element.role,
                    subrole: element.subrole,
                    title: element.title,
                    description: element.description,
                    value: nil,
                    placeholder: element.placeholder,
                    identifier: element.identifier
                )
                : element
        )
    }

    // MARK: - Accessibility notifications

    func handleAccessibilityNotification(_ notification: String, element: AXUIElement) {
        guard !stopped, recorderState == .running else {
            return
        }
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            // Focus alone writes no event; the next keystroke re-reads it.
            focusContext = nil
        case kAXValueChangedNotification:
            // Observed for terminals only; read once when output settles.
            terminalChanged = true
            scheduleTerminalFlush()
        case kAXTitleChangedNotification:
            // Chromium and Electron post title changes for page elements too.
            // Only the focused window's title can change the window context.
            if let lastWindowElement, !CFEqual(element, lastWindowElement) {
                return
            }
            debounce(notification, delay: 0.1) { [weak self] in
                self?.refreshWindow()
            }
        case kAXFocusedWindowChangedNotification:
            focusContext = nil
            debounce(notification, delay: 0.1) { [weak self] in
                self?.refreshWindow()
            }
        case kAXSelectedTextChangedNotification:
            // Fires on every caret move while typing; one request tells a
            // caret from a selection before any context is read.
            debounce(notification, delay: 0.25) { [weak self] in
                self?.checkSelection(of: element)
            }
        default:
            break
        }
    }

    private func debounce(_ key: String, delay: TimeInterval, _ body: @escaping () -> Void) {
        axDebounceTasks[key]?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.axDebounceTasks.removeValue(forKey: key)
            guard let self, !self.stopped, self.recorderState == .running else {
                return
            }
            body()
        }
        axDebounceTasks[key] = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func checkSelection(of element: AXUIElement?) {
        guard !stopped, recorderState == .running else {
            return
        }
        if let element,
           let range = AccessibilityReader.selectedRange(of: element),
           range.length <= 0
        {
            return
        }
        appendSelection(contextSnapshot())
    }

    // MARK: - Applications and observers

    private func observeWorkspace() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }
            self?.switchFrontmostApplication(to: app)
        }
        observePresence()
        mediaOwners = MediaPlaybackMonitor.currentOwners()
        for owner in mediaOwners.values.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }) {
            appendMedia(.mediaPlaybackStarted, owner: owner)
        }
        startMediaTimer()
    }

    private func startMediaTimer() {
        mediaTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
            [weak self] _ in
            self?.pollMediaPlayback()
        }
        timer.tolerance = 5
        mediaTimer = timer
    }

    private func pollMediaPlayback() {
        let current = MediaPlaybackMonitor.currentOwners()
        let changes = MediaPlayback.transitions(previous: mediaOwners, current: current)
        mediaOwners = current
        changes.stopped.forEach { appendMedia(.mediaPlaybackStopped, owner: $0) }
        changes.started.forEach { appendMedia(.mediaPlaybackStarted, owner: $0) }
    }

    private func appendMedia(_ kind: HistoryEventKind, owner: MediaPlaybackOwner) {
        guard !stopped, recorderState == .running else {
            return
        }
        sequence += 1
        let event = HistoryEvent(
            id: sequence,
            timestamp: Date(),
            kind: kind,
            app: EventStreamApp(
                name: owner.name,
                secureInput: false,
                processIdentifier: nil,
                bundleIdentifier: owner.bundleIdentifier
            ),
            diagnostic: owner.assertionName.map { EventStreamDiagnostic(message: $0) }
        )
        let suppressed = policy.shouldSuppress(
            bundleIdentifier: owner.bundleIdentifier,
            windowTitle: nil,
            urlDomain: nil,
            role: nil,
            subrole: nil
        ) != nil
        try? suppressed ? store.appendSuppressed(event) : store.append(event)
    }

    /// Lock, unlock, sleep, and wake bound the time the user can be at the
    /// Mac. Idle time needs no event: it is the gap between recorded events.
    private func observePresence() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()
        let sources: [(NotificationCenter, Notification.Name, HistoryEventKind)] = [
            (distributedCenter, Notification.Name("com.apple.screenIsLocked"), .systemScreenLocked),
            (distributedCenter, Notification.Name("com.apple.screenIsUnlocked"), .systemScreenUnlocked),
            (workspaceCenter, NSWorkspace.willSleepNotification, .systemWillSleep),
            (workspaceCenter, NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        presenceObservers = sources.map { center, name, kind in
            let observer = center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                self?.appendPresence(kind)
            }
            return (center, observer)
        }
    }

    private func appendPresence(_ kind: HistoryEventKind) {
        guard !stopped, recorderState == .running else {
            return
        }
        flushTextBuffer()
        flushTerminalBuffer()
        if kind == .systemScreenLocked || kind == .systemWillSleep {
            cancelPageText()
        }
        try? append(kind: kind, snapshot: nil)
    }

    private func switchFrontmostApplication(to application: NSRunningApplication) {
        guard !stopped else {
            return
        }
        guard recorderState == .running else {
            // Paused: remember the app, touch nothing in it.
            currentProcessIdentifier = application.processIdentifier
            return
        }
        flushTextBuffer()
        flushTerminalBuffer()
        windowRetryTask?.cancel()
        windowRetryTask = nil
        windowRetryCount = 0
        focusContext = nil
        lastWindowElement = nil
        currentProcessIdentifier = application.processIdentifier
        installAccessibilityObserver(processIdentifier: application.processIdentifier)
        refreshWindow()
    }

    private func startObservingFrontmostApplication() {
        if let application = NSWorkspace.shared.frontmostApplication {
            currentProcessIdentifier = application.processIdentifier
        }
        if let currentProcessIdentifier {
            installAccessibilityObserver(processIdentifier: currentProcessIdentifier)
        }
    }

    /// Chromium and Electron build their web accessibility tree only while an
    /// assistive client requests it, and keeping it costs them CPU and energy
    /// on every page change for the rest of the process's life. The recorder
    /// requests it only when `webAccessibility` is `manual` for the app, only
    /// through `AXManualAccessibility` (never `AXEnhancedUserInterface`, the
    /// most expensive mode, which also slows window managers), and clears it
    /// again when recording pauses or stops.
    private func requestWebAccessibilityIfConfigured(processIdentifier: pid_t) {
        let bundleIdentifier = NSRunningApplication(
            processIdentifier: processIdentifier
        )?.bundleIdentifier
        guard policy.webAccessibility.requestsAccessibility(for: bundleIdentifier),
              webAccessibilityProcesses.insert(processIdentifier).inserted
        else {
            return
        }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(processIdentifier),
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    /// Undoes `requestWebAccessibilityIfConfigured` for every app it touched.
    private func releaseWebAccessibility() {
        for processIdentifier in webAccessibilityProcesses
            where NSRunningApplication(processIdentifier: processIdentifier) != nil
        {
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(processIdentifier),
                "AXManualAccessibility" as CFString,
                kCFBooleanFalse
            )
        }
        webAccessibilityProcesses.removeAll()
    }

    private func installAccessibilityObserver(processIdentifier: pid_t) {
        requestWebAccessibilityIfConfigured(processIdentifier: processIdentifier)
        removeAccessibilityObserver()

        var observer: AXObserver?
        guard AXObserverCreate(processIdentifier, accessibilityCallback, &observer) == .success,
              let observer
        else {
            return
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var notifications = [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXTitleChangedNotification,
            kAXSelectedTextChangedNotification,
        ]
        // Value changes only produce events for terminals. Elsewhere (web
        // pages, editors, streaming chat output) they fire continuously.
        if isTerminal(NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier) {
            notifications.append(kAXValueChangedNotification)
        }
        for notification in notifications {
            AXObserverAddNotification(observer, application, notification as CFString, pointer)
        }
        accessibilityObserver = observer
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    private func removeAccessibilityObserver() {
        if let accessibilityObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(accessibilityObserver),
                .defaultMode
            )
        }
        accessibilityObserver = nil
    }

    // MARK: - Snapshots

    /// Cheap context read (no tree) of the frontmost app.
    private func contextSnapshot(at point: CGPoint? = nil) -> AccessibilitySnapshot? {
        guard let currentProcessIdentifier,
              var snapshot = AccessibilityReader.context(
                  processIdentifier: currentProcessIdentifier,
                  at: point,
                  urlResolver: urlResolver,
                  browserScripting: browserScripting
              )
        else {
            return nil
        }
        if let windowElement = snapshot.windowElement {
            lastWindowElement = windowElement
        }
        applyURLCache(&snapshot)
        observePageText(snapshot)
        return snapshot
    }

    /// Context plus, when the event kind carries a tree and the throttle
    /// allows it, a fresh tree capture.
    private func eventSnapshot(
        kind: HistoryEventKind,
        at point: CGPoint? = nil,
        context: AccessibilitySnapshot? = nil,
        forceTree: Bool = false
    ) -> AccessibilitySnapshot? {
        guard let snapshot = context ?? contextSnapshot(at: point) else {
            return nil
        }
        return withTree(snapshot, kind: kind, force: forceTree)
    }

    private func withTree(
        _ snapshot: AccessibilitySnapshot,
        kind: HistoryEventKind,
        force: Bool
    ) -> AccessibilitySnapshot {
        guard shouldIncludeAX(kind), suppressionReason(snapshot) == nil else {
            return snapshot
        }
        let key = axRevisionKey(snapshot)
        let context = "\(snapshot.window?.title ?? "")\u{1F}\(snapshot.window?.url ?? "")"
        guard captureThrottle.shouldCapture(windowKey: key, context: context, force: force)
        else {
            return snapshot
        }
        var captured = AccessibilityReader.captureTree(
            snapshot,
            settings: policy.axCapture,
            urlResolver: urlResolver
        )
        applyURLCache(&captured)
        captureThrottle.recordCapture(windowKey: key, context: context)
        return captured
    }

    private func applyURLCache(_ snapshot: inout AccessibilitySnapshot) {
        guard let windowKey = snapshot.windowKey else {
            return
        }
        if let url = snapshot.window?.url {
            if latestURLByWindowKey.count > 256 {
                latestURLByWindowKey.removeAll()
            }
            latestURLByWindowKey[windowKey] = url
        } else if let cachedURL = latestURLByWindowKey[windowKey] {
            snapshot = snapshot.replacingWindowURL(cachedURL)
        }
    }

    private func suppressionReason(_ snapshot: AccessibilitySnapshot) -> String? {
        policy.shouldSuppress(
            bundleIdentifier: snapshot.app.bundleIdentifier ?? "",
            windowTitle: snapshot.window?.title,
            urlDomain: ObservationPolicy.normalizedDomain(snapshot.window?.url),
            role: snapshot.element?.role,
            subrole: snapshot.element?.subrole,
            privateWindow: snapshot.isPrivateWindow
        )
    }

    // MARK: - Page text

    /// Tracks the frontmost page for the opt-in `pageText` reader. Costs no
    /// requests: it only looks at the context this event already read.
    private func observePageText(_ snapshot: AccessibilitySnapshot) {
        guard policy.pageText.isEnabled else {
            return
        }
        var candidate: PageTextDwellTracker.Candidate?
        if let bundleIdentifier = snapshot.app.bundleIdentifier,
           policy.pageText.applies(to: bundleIdentifier),
           let urlKey = WebURL.matchKey(snapshot.window?.url)
        {
            candidate = PageTextDwellTracker.Candidate(
                bundleIdentifier: bundleIdentifier,
                windowKey: snapshot.windowKey ?? "pid:\(snapshot.processIdentifier)",
                urlKey: urlKey
            )
        }
        pageTextSnapshot = candidate == nil ? nil : snapshot
        let now = Date()
        guard candidate != pageTextTracker.current else {
            return
        }
        pageTextTask?.cancel()
        pageTextTask = nil
        guard let dueAt = pageTextTracker.observe(candidate, now: now) else {
            return
        }
        let task = DispatchWorkItem { [weak self] in
            self?.pageTextTask = nil
            self?.readPageTextIfDue()
        }
        pageTextTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(dueAt.timeIntervalSince(now), 0),
            execute: task
        )
    }

    private func readPageTextIfDue() {
        let now = Date()
        guard !stopped, recorderState == .running, !pageTextInFlight,
              let candidate = pageTextTracker.due(now: now),
              let snapshot = pageTextSnapshot,
              snapshot.processIdentifier == currentProcessIdentifier,
              let pageURL = snapshot.window?.url
        else {
            return
        }
        let refusal = PageTextEligibility.refusal(
            settings: policy.pageText,
            captureText: policy.captureText,
            bundleIdentifier: snapshot.app.bundleIdentifier,
            url: pageURL,
            suppressionReason: suppressionReason(snapshot),
            secureInput: snapshot.app.secureInput,
            secureEventInput: IsSecureEventInputEnabled()
        )
        guard refusal == nil else {
            return
        }
        pageTextTracker.recordAttempt(candidate.urlKey, now: now)
        pageTextInFlight = true
        pageTextReader.read(
            pageURL: pageURL,
            title: snapshot.window?.title,
            settings: policy.pageText
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.pageTextInFlight = false
                guard case let .success(page) = result,
                      WebURL.matchKey(page.url) == candidate.urlKey
                else {
                    return
                }
                self.appendPageText(page, snapshot: snapshot)
            }
        }
    }

    private func appendPageText(_ page: PageTextResult, snapshot: AccessibilitySnapshot) {
        guard !stopped, recorderState == .running, !page.text.isEmpty else {
            return
        }
        sequence += 1
        let shown = page.text.count
        let event = HistoryEvent(
            id: sequence,
            timestamp: Date(),
            kind: .webPageContent,
            app: snapshot.app,
            window: snapshot.window,
            ax: EventStreamAXTree(mode: .fullTree, text: page.text),
            diagnostic: EventStreamDiagnostic(
                message: "cdp \(page.element ?? "body") \(shown)/\(max(page.length, shown))"
            )
        )
        try? store.append(event)
    }

    private func cancelPageText() {
        pageTextTask?.cancel()
        pageTextTask = nil
        pageTextSnapshot = nil
        _ = pageTextTracker.observe(nil, now: Date())
    }

    // MARK: - Writing

    private func append(
        kind: HistoryEventKind,
        snapshot: AccessibilitySnapshot?,
        mouse: EventStreamMouseInteraction? = nil,
        keyboard: EventStreamKeyboardInteraction? = nil,
        selection: EventStreamSelection? = nil,
        diagnostic: EventStreamDiagnostic? = nil
    ) throws {
        sequence += 1
        let suppressionReason = snapshot.flatMap { self.suppressionReason($0) }
        let isBoundary = kind.isBoundary
        let eventSnapshot = isBoundary && suppressionReason != nil ? nil : snapshot
        let event = HistoryEvent(
            id: sequence,
            timestamp: Date(),
            kind: kind,
            app: eventSnapshot?.app,
            window: eventSnapshot?.window,
            mouse: mouse,
            keyboard: keyboard,
            selection: selection,
            ax: shouldIncludeAX(kind)
                ? axTree(
                    for: eventSnapshot,
                    forceFull: kind == .keyboardSubmit
                )
                : nil,
            diagnostic: diagnostic
        )

        if isBoundary {
            try store.append(event)
            return
        }
        guard snapshot != nil else {
            try store.appendSuppressed(event)
            return
        }
        if suppressionReason != nil {
            try store.appendSuppressed(event)
        } else {
            try store.append(event)
        }
    }

    private func axTree(
        for snapshot: AccessibilitySnapshot?,
        forceFull: Bool = false
    ) -> EventStreamAXTree? {
        guard let snapshot, let revision = snapshot.axRevision else {
            return nil
        }
        guard let windowKey = axRevisionKey(snapshot) else {
            return EventStreamAXTree(mode: .fullTree, text: revision.fullText())
        }
        let previous = previousAXRevisionByWindowKey[windowKey]
        previousAXRevisionByWindowKey[windowKey] = revision
        if forceFull {
            return EventStreamAXTree(mode: .fullTree, text: revision.fullText())
        }
        if let previous {
            return EventStreamAXTree(
                mode: .diffFromPrevious,
                text: revision.diff(from: previous)
            )
        }
        return EventStreamAXTree(mode: .fullTree, text: revision.fullText())
    }

    private func minimalMouseTarget(
        _ element: EventStreamAXElement?
    ) -> EventStreamAXElement? {
        guard let role = element?.role else {
            return nil
        }
        return EventStreamAXElement(
            role: role,
            subrole: nil,
            title: nil,
            description: nil,
            value: nil,
            placeholder: nil,
            identifier: nil
        )
    }

    private func axRevisionKey(_ snapshot: AccessibilitySnapshot) -> String? {
        if let windowKey = snapshot.windowKey {
            return windowKey
        }
        let bundleIdentifier = snapshot.app.bundleIdentifier ?? ""
        let title = snapshot.window?.title ?? ""
        guard !bundleIdentifier.isEmpty || !title.isEmpty else {
            return nil
        }
        return "context:\(bundleIdentifier)\u{1F}\(title)"
    }

    /// Writes `window.changed` when the window context differs from the last
    /// one written. The context read is cheap; the tree is captured only when
    /// an event will actually be written.
    private func refreshWindow() {
        guard !stopped, recorderState == .running else {
            return
        }
        guard let snapshot = contextSnapshot(),
              let title = snapshot.window?.title,
              !title.isEmpty
        else {
            scheduleWindowRetry()
            return
        }
        let signature = [
            snapshot.app.bundleIdentifier ?? "",
            snapshot.window?.title ?? "",
            snapshot.window?.url ?? "",
            snapshot.windowKey ?? "",
            snapshot.element?.role ?? "",
            snapshot.element?.title ?? "",
            snapshot.element?.identifier ?? "",
        ].joined(separator: "\u{1F}")
        guard signature != lastWindowSignature else {
            windowRetryTask?.cancel()
            windowRetryTask = nil
            windowRetryCount = 0
            return
        }
        let captured = withTree(snapshot, kind: .windowChanged, force: true)
        guard captured.axRevision != nil || suppressionReason(captured) != nil else {
            scheduleWindowRetry()
            return
        }
        windowRetryTask?.cancel()
        windowRetryTask = nil
        windowRetryCount = 0
        lastWindowSignature = signature
        try? append(kind: .windowChanged, snapshot: captured)
    }

    private func scheduleWindowRetry() {
        guard windowRetryTask == nil, windowRetryCount < 10 else {
            return
        }
        windowRetryCount += 1
        let task = DispatchWorkItem { [weak self] in
            self?.windowRetryTask = nil
            self?.refreshWindow()
        }
        windowRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }

    private func keyEquivalent(_ event: CGEvent) -> String? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let named: [Int64: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete",
            53: "escape", 76: "enter", 123: "left", 124: "right",
            125: "down", 126: "up",
        ]
        if let name = named[keyCode] {
            return name
        }
        return NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
    }

    private func modifierNames(_ flags: CGEventFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.maskCommand) { result.append("command") }
        if flags.contains(.maskControl) { result.append("control") }
        if flags.contains(.maskAlternate) { result.append("option") }
        if flags.contains(.maskShift) { result.append("shift") }
        if flags.contains(.maskSecondaryFn) { result.append("fn") }
        return result
    }

    private func mouseButton(for type: CGEventType) -> String {
        switch type {
        case .rightMouseDown, .rightMouseUp:
            return "right"
        case .otherMouseDown, .otherMouseUp:
            return "other"
        default:
            return "left"
        }
    }

    private func isTerminal(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        return [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
        ].contains(bundleIdentifier)
    }

    private func appendSelection(_ snapshot: AccessibilitySnapshot?) {
        guard let snapshot else {
            return
        }
        let selectedText = policy.captureText ? snapshot.selectedText : nil
        let selectedRange = snapshot.selectedRange
        guard selectedText?.isEmpty == false ||
                (selectedRange?.length ?? 0) > 0 else {
            return
        }
        let signature = [
            snapshot.element?.identifier ?? "",
            selectedText ?? "",
            selectedRange.map { "\($0.location):\($0.length)" } ?? "",
        ].joined(separator: "\u{1F}")
        guard signature != lastSelectionSignature else {
            return
        }
        lastSelectionSignature = signature
        let selection = EventStreamSelection(
            target: snapshot.element,
            selectedText: selectedText,
            selectedRange: selectedRange,
            selectedItems: snapshot.app.secureInput
                ? []
                : AccessibilityReader.selectedItems(from: snapshot.focusedElement)
        )
        try? append(
            kind: .selectionChanged,
            snapshot: snapshot,
            selection: selection
        )
    }

    private func shouldIncludeAX(_ kind: HistoryEventKind) -> Bool {
        kind.carriesAXTree
    }

    // MARK: - Pause and resume

    /// Watches the history home directory for control changes instead of
    /// polling. `control.json` is replaced atomically (write + rename), which
    /// changes the directory's entries; a watch on the file itself would be
    /// orphaned by the rename.
    private func watchControl() {
        controlWatcher?.cancel()
        controlWatcher = nil
        let path = runtimeControl.homeURL.path
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        let descriptor = open(path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, !self.stopped else {
                    return
                }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.watchControl()
                }
                self.scheduleControlCheck()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            controlWatcher = source
            source.resume()
        }
        if controlFallbackTimer == nil {
            // Safety net for a missed event or a directory that could not be
            // watched; the watch handles changes in normal operation.
            let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
                [weak self] _ in
                guard let self else {
                    return
                }
                if self.controlWatcher == nil {
                    self.watchControl()
                }
                self.reconcileControlState()
            }
            timer.tolerance = 60
            controlFallbackTimer = timer
        }
    }

    private func scheduleControlCheck() {
        guard controlCheckTask == nil else {
            return
        }
        // Coalesces the burst of directory events from one atomic write.
        let task = DispatchWorkItem { [weak self] in
            self?.controlCheckTask = nil
            self?.reconcileControlState()
        }
        controlCheckTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }

    private func scheduleResume(at date: Date?) {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard let date else {
            return
        }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            self?.resumeTimer = nil
            self?.reconcileControlState()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    private func reconcileControlState() {
        guard !stopped, let control = runtimeControl.readControl() else {
            return
        }
        let requested: RecorderState
        if control.state == .paused,
           let resumeAt = control.resumeAt,
           resumeAt <= Date()
        {
            requested = .running
            try? runtimeControl.writeControl(.running)
        } else {
            requested = control.state
        }
        scheduleResume(at: requested == .paused ? control.resumeAt : nil)
        switch (recorderState, requested) {
        case (.running, .paused):
            flushTextBuffer()
            flushTerminalBuffer()
            recorderState = .paused
            suspendObservation()
            try? writeRuntimeStatus(state: .paused)
        case (.paused, .running):
            recorderState = .running
            lastWindowSignature = nil
            resumeObservation()
            try? writeRuntimeStatus(state: .running)
            refreshWindow()
        default:
            break
        }
    }

    /// Paused costs nothing in other apps: no event tap, no accessibility
    /// observer, no web accessibility mode requested by the recorder, no
    /// pending accessibility work, no media polling.
    private func suspendObservation() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        removeAccessibilityObserver()
        releaseWebAccessibility()
        axDebounceTasks.values.forEach { $0.cancel() }
        axDebounceTasks.removeAll()
        windowRetryTask?.cancel()
        windowRetryTask = nil
        windowRetryCount = 0
        mediaTimer?.invalidate()
        mediaTimer = nil
        mouseDown = nil
        focusContext = nil
        lastWindowElement = nil
        cancelPageText()
    }

    private func resumeObservation() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        startObservingFrontmostApplication()
        pollMediaPlayback()
        startMediaTimer()
    }

    private func writeRuntimeStatus(
        state: RecorderState,
        endedAt: Date? = nil
    ) throws {
        try runtimeControl.writeRuntime(
            RecorderRuntimeStatus(
                state: state,
                processIdentifier: state == .stopped ? nil : getpid(),
                eventStreamRootPath: store.homeURL.path,
                currentSegmentEventsPath: state == .stopped ? nil : store.eventsURL.path,
                currentSegmentMetadataPath: state == .stopped ? nil : store.metadataURL.path,
                suppressedEventsPath: state == .stopped
                    ? nil
                    : store.suppressedEventsURL?.path,
                startedAt: recorderStartedAt,
                endedAt: endedAt
            )
        )
    }

    private func rotateSegment() {
        guard !stopped, recorderState == .running else {
            return
        }
        flushTextBuffer()
        flushTerminalBuffer()
        let homeURL = store.homeURL
        do {
            try store.finish(reason: "segment_rotated")
            store = try SegmentStore(homeURL: homeURL)
            try writeRuntimeStatus(state: .running)
        } catch {
            try? append(
                kind: .debugError,
                snapshot: eventSnapshot(kind: .debugError),
                diagnostic: EventStreamDiagnostic(
                    message: "Segment rotation failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func scheduleTerminalFlush() {
        terminalFlushTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.flushTerminalBuffer()
        }
        terminalFlushTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func flushTerminalBuffer() {
        terminalFlushTask?.cancel()
        terminalFlushTask = nil
        guard terminalChanged else {
            return
        }
        terminalChanged = false
        guard let snapshot = eventSnapshot(kind: .terminalValueChanged),
              isTerminal(snapshot.app.bundleIdentifier)
        else {
            return
        }
        try? append(
            kind: .terminalValueChanged,
            snapshot: snapshot,
            keyboard: EventStreamKeyboardInteraction(
                text: policy.captureText ? snapshot.element?.value : nil,
                keyEquivalent: nil,
                modifiers: [],
                target: snapshot.element
            )
        )
    }
}
