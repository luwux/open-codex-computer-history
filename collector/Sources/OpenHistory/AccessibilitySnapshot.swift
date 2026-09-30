import AppKit
import ApplicationServices
import Foundation
import HistoryCore

struct AccessibilitySnapshot {
    let app: EventStreamApp
    let window: EventStreamWindow?
    /// Recorder-internal identity of the focused window, stable across
    /// requests (derived from the accessibility element, not the title).
    let windowKey: String?
    let element: EventStreamAXElement?
    let selectedText: String?
    let selectedRange: EventStreamTextRange?
    var axRevision: AXTreeRevisionSnapshot?

    let processIdentifier: pid_t
    let windowElement: AXUIElement?
    let focusedElement: AXUIElement?

    var dragEndpoint: EventStreamMouseDragEndpoint {
        EventStreamMouseDragEndpoint(app: app, window: window, element: element)
    }

    func replacingWindowURL(_ url: String?) -> AccessibilitySnapshot {
        AccessibilitySnapshot(
            app: app,
            window: EventStreamWindow(
                title: window?.title,
                url: url,
                windowID: nil
            ),
            windowKey: windowKey,
            element: element,
            selectedText: selectedText,
            selectedRange: selectedRange,
            axRevision: axRevision,
            processIdentifier: processIdentifier,
            windowElement: windowElement,
            focusedElement: focusedElement
        )
    }

    func replacingElement(_ element: EventStreamAXElement?) -> AccessibilitySnapshot {
        AccessibilitySnapshot(
            app: app,
            window: window,
            windowKey: windowKey,
            element: element,
            selectedText: selectedText,
            selectedRange: selectedRange,
            axRevision: axRevision,
            processIdentifier: processIdentifier,
            windowElement: windowElement,
            focusedElement: focusedElement
        )
    }
}

enum AccessibilityReader {
    private static let applicationAttributes: [CFString] = [
        kAXFocusedWindowAttribute as CFString,
        kAXFocusedUIElementAttribute as CFString,
        "AXURL" as CFString,
        "AXDocument" as CFString,
    ]

    private static let windowAttributes: [CFString] = [
        kAXTitleAttribute as CFString,
        "AXURL" as CFString,
        "AXDocument" as CFString,
    ]

    static let elementAttributes: [CFString] = [
        kAXRoleAttribute as CFString,
        kAXSubroleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXPlaceholderValueAttribute as CFString,
        kAXIdentifierAttribute as CFString,
    ]

    private static let focusedAttributes: [CFString] = elementAttributes + [
        "AXURL" as CFString,
        "AXDocument" as CFString,
        kAXSelectedTextAttribute as CFString,
        kAXSelectedTextRangeAttribute as CFString,
    ]

    /// Reads the cheap context of the frontmost window: app, window title and
    /// URL, and the focused element (or the element at `point`). Costs three
    /// or four requests, plus one for a browser URL once it is cached.
    static func context(
        processIdentifier: pid_t,
        at point: CGPoint? = nil,
        urlResolver: BrowserURLResolver? = nil
    ) -> AccessibilitySnapshot? {
        guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let application = AXAttributeValues(appElement, applicationAttributes)
        let windowElement = application.element(kAXFocusedWindowAttribute as CFString)
        var focusedElement = point.flatMap {
            elementAtPosition(appElement, point: $0)
        } ?? notApplication(application.element(kAXFocusedUIElementAttribute as CFString), appElement)

        let window = AXAttributeValues(windowElement, windowAttributes)
        var focused = AXAttributeValues(focusedElement, focusedAttributes)
        if point == nil, focused.status != .success {
            // Web views replace the focused node while re-rendering, so the
            // element can be missing or already invalid; ask once more.
            if let value = axCopyAttribute(appElement, kAXFocusedUIElementAttribute as CFString),
               CFGetTypeID(value) == AXUIElementGetTypeID(),
               let element = notApplication((value as! AXUIElement), appElement)
            {
                focusedElement = element
                focused = AXAttributeValues(focusedElement, focusedAttributes)
            }
        }
        let windowTitle = window.string(kAXTitleAttribute as CFString)
        let windowKey = windowElement.map {
            "window:\(processIdentifier):\(CFHash($0))"
        }

        var url: String?
        for values in [focused, window, application] {
            for name in ["AXURL" as CFString, "AXDocument" as CFString] {
                if url == nil, let value = values.string(name), !value.isEmpty {
                    url = value
                }
            }
        }
        let bundleIdentifier = runningApplication.bundleIdentifier
        let resolvedURL = BrowserURLResolver.normalizedWebURL(url)
            ?? urlResolver?.url(
                window: windowElement,
                windowKey: windowKey,
                title: windowTitle,
                bundleIdentifier: bundleIdentifier
            )

        let role = focused.string(kAXRoleAttribute as CFString)
        let subrole = focused.string(kAXSubroleAttribute as CFString)
        let secureInput = ObservationPolicy.isSecureRole(role, subrole: subrole)
        let element = focusedElement.map { _ in
            eventElement(focused, includeValue: !secureInput)
        }
        let selectedRange = focused.range(kAXSelectedTextRangeAttribute as CFString).map {
            EventStreamTextRange(location: $0.location, length: $0.length)
        }

        return AccessibilitySnapshot(
            app: EventStreamApp(
                name: runningApplication.localizedName,
                secureInput: secureInput,
                processIdentifier: nil,
                bundleIdentifier: bundleIdentifier
            ),
            window: EventStreamWindow(
                title: windowTitle,
                url: resolvedURL,
                windowID: nil
            ),
            windowKey: windowKey,
            element: element,
            selectedText: secureInput
                ? nil
                : focused.string(kAXSelectedTextAttribute as CFString),
            selectedRange: selectedRange,
            axRevision: nil,
            processIdentifier: processIdentifier,
            windowElement: windowElement,
            focusedElement: focusedElement
        )
    }

    /// Context plus the window's accessibility tree.
    static func snapshot(
        processIdentifier: pid_t,
        at point: CGPoint? = nil,
        includeTree: Bool = true,
        settings: AXCaptureSettings = AXCaptureSettings(),
        urlResolver: BrowserURLResolver? = nil
    ) -> AccessibilitySnapshot? {
        guard var snapshot = context(
            processIdentifier: processIdentifier,
            at: point,
            urlResolver: urlResolver
        ) else {
            return nil
        }
        if includeTree {
            snapshot = captureTree(snapshot, settings: settings, urlResolver: urlResolver)
        }
        return snapshot
    }

    /// Adds the window's tree to a context snapshot.
    static func captureTree(
        _ snapshot: AccessibilitySnapshot,
        settings: AXCaptureSettings,
        urlResolver: BrowserURLResolver?
    ) -> AccessibilitySnapshot {
        guard let result = AXTreeCapture.capture(
            root: snapshot.windowElement ?? snapshot.focusedElement,
            secureInput: snapshot.app.secureInput,
            settings: settings
        ) else {
            return snapshot
        }
        var snapshot = snapshot
        snapshot.axRevision = result.revision
        if let webArea = result.webArea,
           let url = BrowserURLResolver.normalizedWebURL(result.webAreaURL)
        {
            urlResolver?.noteWebArea(
                webArea,
                windowKey: snapshot.windowKey,
                title: snapshot.window?.title,
                bundleIdentifier: snapshot.app.bundleIdentifier
            )
            if snapshot.window?.url == nil {
                snapshot = snapshot.replacingWindowURL(url)
            }
        }
        return snapshot
    }

    /// Reads the element's attributes in one request.
    static func eventElement(_ element: AXUIElement, includeValue: Bool) -> EventStreamAXElement {
        eventElement(AXAttributeValues(element, elementAttributes), includeValue: includeValue)
    }

    private static func eventElement(
        _ values: AXAttributeValues,
        includeValue: Bool
    ) -> EventStreamAXElement {
        EventStreamAXElement(
            role: values.string(kAXRoleAttribute as CFString),
            subrole: values.string(kAXSubroleAttribute as CFString),
            title: values.string(kAXTitleAttribute as CFString),
            description: values.string(kAXDescriptionAttribute as CFString),
            value: includeValue ? values.string(kAXValueAttribute as CFString) : nil,
            placeholder: values.string(kAXPlaceholderValueAttribute as CFString),
            identifier: values.string(kAXIdentifierAttribute as CFString)
        )
    }

    /// Selected children or rows of the focused element, read only when a
    /// selection event is about to be written.
    static func selectedItems(from element: AXUIElement?) -> [EventStreamAXElement] {
        let values = AXAttributeValues(element, [
            kAXSelectedChildrenAttribute as CFString,
            kAXSelectedRowsAttribute as CFString,
        ])
        for name in [
            kAXSelectedChildrenAttribute as CFString,
            kAXSelectedRowsAttribute as CFString,
        ] {
            guard let raw = values.elements(name) else {
                continue
            }
            return raw.prefix(50).map { eventElement($0, includeValue: true) }
        }
        return []
    }

    /// Selected text range of one element, in one request. `nil` when the
    /// element has no text selection attribute.
    static func selectedRange(of element: AXUIElement) -> CFRange? {
        AXAttributeValues(element, [kAXSelectedTextRangeAttribute as CFString])
            .range(kAXSelectedTextRangeAttribute as CFString)
    }

    /// The element under `point`, or `nil` when there is none or the hit test
    /// answers with the application element itself (a point outside the
    /// app's windows).
    static func elementAtPosition(
        _ application: AXUIElement,
        point: CGPoint
    ) -> AXUIElement? {
        AXCallCounter.record()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application,
            Float(point.x),
            Float(point.y),
            &element
        ) == .success else {
            return nil
        }
        return notApplication(element, application)
    }

    /// Filters out the application element. Chromium and Electron switch on
    /// their web accessibility mode for the rest of the process's life when
    /// the application element's `AXRole` is read, and every element read
    /// here gets its role read; nothing recorded needs the application's own
    /// attributes beyond the focused window and element.
    private static func notApplication(
        _ element: AXUIElement?,
        _ application: AXUIElement
    ) -> AXUIElement? {
        guard let element, !CFEqual(element, application) else {
            return nil
        }
        return element
    }
}

/// Finds a browser window's page URL without walking the window each time.
///
/// The first lookup for a window title searches the window (one batched
/// request per node) for a web area `AXURL` or the address field. The element
/// found is cached with the title; while the title stays the same, later
/// lookups re-read just that element, so same-title navigations still update.
final class BrowserURLResolver {
    private enum Source {
        case webArea(AXUIElement)
        case addressField(AXUIElement)
    }

    private struct Entry {
        let title: String?
        let source: Source
    }

    private var entries: [String: Entry] = [:]
    private let searchLimit: Int
    private let searchBudgetNanoseconds: UInt64

    init(searchLimit: Int = 300, searchBudgetMilliseconds: Double = 100) {
        self.searchLimit = searchLimit
        self.searchBudgetNanoseconds = UInt64(searchBudgetMilliseconds * 1_000_000)
    }

    func reset() {
        entries.removeAll()
    }

    func url(
        window: AXUIElement?,
        windowKey: String?,
        title: String?,
        bundleIdentifier: String?
    ) -> String? {
        guard let window,
              let bundleIdentifier,
              ObservationPolicy.browserBundleIdentifiers.contains(bundleIdentifier)
        else {
            return nil
        }
        if let windowKey, let entry = entries[windowKey], entry.title == title,
           let url = read(entry.source)
        {
            return url
        }
        guard let (url, source) = search(window) else {
            if let windowKey {
                entries.removeValue(forKey: windowKey)
            }
            return nil
        }
        if let windowKey {
            store(Entry(title: title, source: source), for: windowKey)
        }
        return url
    }

    func noteWebArea(
        _ webArea: AXUIElement,
        windowKey: String?,
        title: String?,
        bundleIdentifier: String?
    ) {
        guard let windowKey,
              let bundleIdentifier,
              ObservationPolicy.browserBundleIdentifiers.contains(bundleIdentifier)
        else {
            return
        }
        store(Entry(title: title, source: .webArea(webArea)), for: windowKey)
    }

    private func store(_ entry: Entry, for windowKey: String) {
        if entries.count > 64 {
            entries.removeAll()
        }
        entries[windowKey] = entry
    }

    private func read(_ source: Source) -> String? {
        switch source {
        case let .webArea(element):
            return Self.normalizedWebURL(
                AXAttributeValues(element, ["AXURL" as CFString]).string("AXURL" as CFString)
            )
        case let .addressField(element):
            return ObservationPolicy.addressBarURL(
                AXAttributeValues(element, [kAXValueAttribute as CFString])
                    .string(kAXValueAttribute as CFString)
            )
        }
    }

    private static let searchAttributes: [CFString] = [
        kAXRoleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXIdentifierAttribute as CFString,
        kAXChildrenAttribute as CFString,
        "AXURL" as CFString,
        "AXDocument" as CFString,
    ]

    private func search(_ root: AXUIElement) -> (String, Source)? {
        let deadline = DispatchTime.now().uptimeNanoseconds + searchBudgetNanoseconds
        var queue = [root]
        var visited = Set<AXElementKey>()
        var index = 0
        while index < queue.count, visited.count < searchLimit,
              DispatchTime.now().uptimeNanoseconds < deadline
        {
            let element = queue[index]
            index += 1
            guard visited.insert(AXElementKey(element: element)).inserted else {
                continue
            }
            let values = AXAttributeValues(element, Self.searchAttributes)
            for name in ["AXURL" as CFString, "AXDocument" as CFString] {
                if let url = Self.normalizedWebURL(values.string(name)) {
                    return (url, .webArea(element))
                }
            }
            let role = values.string(kAXRoleAttribute as CFString)
            let label = [
                values.string(kAXTitleAttribute as CFString),
                values.string(kAXDescriptionAttribute as CFString),
                values.string(kAXIdentifierAttribute as CFString),
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if ObservationPolicy.isBrowserAddressField(role: role, label: label),
               let url = read(.addressField(element))
            {
                return (url, .addressField(element))
            }
            queue.append(contentsOf: values.elements(kAXChildrenAttribute as CFString) ?? [])
        }
        return nil
    }

    static func normalizedWebURL(_ value: String?) -> String? {
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url.absoluteString
    }
}
