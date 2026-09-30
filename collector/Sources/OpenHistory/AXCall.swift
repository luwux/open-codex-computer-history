import ApplicationServices
import Foundation
import HistoryCore

/// Counts cross-process accessibility requests. Each one is answered on the
/// target application's main thread, so the count is the cost we impose.
enum AXCallCounter {
    private(set) static var count = 0
    static func reset() { count = 0 }
    static func record(_ calls: Int = 1) { count += calls }
}

/// Bounds every accessibility request this process makes. The system
/// default is six seconds, which lets one busy application stall the
/// recorder that long. Setting it on the system-wide element changes the
/// process-wide default.
func configureAXMessagingTimeout(_ settings: AXCaptureSettings) {
    AXUIElementSetMessagingTimeout(
        AXUIElementCreateSystemWide(),
        Float(max(settings.messagingTimeoutMilliseconds, 10) / 1000)
    )
}

func axCopyAttribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    AXCallCounter.record()
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return nil
    }
    return value
}

/// Reads several attributes of one element in a single request. Missing or
/// unsupported attributes come back as `nil` (the API reports them as
/// `AXValue` error placeholders, which are filtered here).
func axCopyAttributes(_ element: AXUIElement, _ names: [CFString]) -> [CFTypeRef?] {
    axCopyAttributesWithStatus(element, names).values
}

/// `axCopyAttributes` plus the request's status, which is not `.success`
/// when the element is gone or the application did not answer in time.
func axCopyAttributesWithStatus(
    _ element: AXUIElement,
    _ names: [CFString]
) -> (values: [CFTypeRef?], status: AXError) {
    AXCallCounter.record()
    var values: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
        element,
        names as CFArray,
        AXCopyMultipleAttributeOptions(rawValue: 0),
        &values
    )
    guard status == .success,
          let array = values as [AnyObject]?,
          array.count == names.count
    else {
        return (Array(repeating: nil, count: names.count), status == .success ? .failure : status)
    }
    return (array.map { value in
        let reference = value as CFTypeRef
        if CFGetTypeID(reference) == AXValueGetTypeID(),
           AXValueGetType(reference as! AXValue) == .axError
        {
            return nil
        }
        if CFGetTypeID(reference) == CFNullGetTypeID() {
            return nil
        }
        return reference
    }, .success)
}

/// Typed view over one `axCopyAttributes` result.
struct AXAttributeValues {
    private let values: [String: CFTypeRef]
    /// Status of the request; `.noValue` when there was no element.
    let status: AXError

    init(_ element: AXUIElement?, _ names: [CFString]) {
        guard let element else {
            values = [:]
            status = .noValue
            return
        }
        let result = axCopyAttributesWithStatus(element, names)
        var values: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, result.values) {
            if let value {
                values[name as String] = value
            }
        }
        self.values = values
        self.status = result.status
    }

    func raw(_ name: CFString) -> CFTypeRef? {
        values[name as String]
    }

    func string(_ name: CFString) -> String? {
        let value = values[name as String]
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return nil
    }

    func bool(_ name: CFString) -> Bool? {
        values[name as String] as? Bool
    }

    func element(_ name: CFString) -> AXUIElement? {
        guard let value = values[name as String],
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    func elements(_ name: CFString) -> [AXUIElement]? {
        values[name as String] as? [AXUIElement]
    }

    func range(_ name: CFString) -> CFRange? {
        guard let value = values[name as String],
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }
}

/// Identity of an accessibility element for caches. Elements obtained by
/// separate requests compare equal with `CFEqual` when they name the same
/// object, so this key needs no further requests.
struct AXElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
