import AppKit
import ApplicationServices
import Darwin
import Foundation

@main
struct OpenHistoryFixtureDriver {
    static func main() {
        do {
            try run()
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        guard AXIsProcessTrusted() else {
            throw DriverError("Accessibility permission is required.")
        }
        guard let app = waitForApplication(timeout: 10) else {
            throw DriverError("Open History Fixture is not running.")
        }
        app.activate()
        Thread.sleep(forTimeInterval: 0.4)

        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let window = elementAttribute(
            root,
            kAXFocusedWindowAttribute as CFString
        ) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        let controls: [(String, AXUIElement?)] = [
            ("synthetic-note", waitForElement(root: root, identifier: "synthetic-note")),
            ("synthetic-secret", waitForElement(root: root, identifier: "synthetic-secret")),
            ("synthetic-action", waitForElement(root: root, identifier: "synthetic-action")),
            ("fixture-drag-source", waitForElement(root: root, identifier: "fixture-drag-source")),
            ("fixture-drop-target", waitForElement(root: root, identifier: "fixture-drop-target")),
            ("Beta", waitForElement(root: root, description: "Beta")),
        ]
        let missing = controls.compactMap { name, element in
            element == nil ? name : nil
        }
        guard missing.isEmpty else {
            throw DriverError(
                "Fixture controls not found: \(missing.joined(separator: ", "))"
            )
        }
        let note = controls[0].1!
        let secret = controls[1].1!
        let action = controls[2].1!
        let dragSource = controls[3].1!
        let dropTarget = controls[4].1!
        let beta = controls[5].1!

        try focus(note)
        typeText("synthetic note")
        pressKey(code: 36)
        Thread.sleep(forTimeInterval: 1.0)
        if stringAttribute(note, kAXValueAttribute as CFString) !=
            "synthetic note" {
            AXUIElementSetAttributeValue(
                note,
                kAXValueAttribute as CFString,
                "synthetic note" as CFString
            )
            Thread.sleep(forTimeInterval: 0.4)
        }

        pressKey(code: 15, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.8)

        try focus(beta)
        AXUIElementPerformAction(beta, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.8)

        if let sourcePoint = center(of: dragSource),
           let destinationPoint = center(of: dropTarget)
        {
            drag(from: sourcePoint, to: destinationPoint)
        }
        Thread.sleep(forTimeInterval: 0.8)

        try focus(secret)
        typeText("synthetic secret")
        Thread.sleep(forTimeInterval: 1.0)

        AXUIElementPerformAction(action, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.8)
        print("Fixture actions completed.")
    }

    private static func waitForApplication(
        timeout: TimeInterval
    ) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "dev.opencomputerhistory.fixture"
            ).first {
                return app
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private static func waitForElement(
        root: AXUIElement,
        identifier: String? = nil,
        description: String? = nil,
        timeout: TimeInterval = 8
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = find(
                root: root,
                identifier: identifier,
                description: description
            ) {
                return element
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private static func find(
        root: AXUIElement,
        identifier: String? = nil,
        description: String? = nil
    ) -> AXUIElement? {
        var queue = [root]
        var visited = Set<CFHashCode>()
        while !queue.isEmpty {
            let element = queue.removeFirst()
            guard visited.insert(CFHash(element)).inserted else {
                continue
            }
            let currentIdentifier = stringAttribute(
                element,
                kAXIdentifierAttribute as CFString
            )
            let currentDescription = stringAttribute(
                element,
                kAXDescriptionAttribute as CFString
            )
            if identifier.map({ $0 == currentIdentifier }) ?? true,
               description.map({ $0 == currentDescription }) ?? true,
               identifier != nil || description != nil
            {
                return element
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func focus(_ element: AXUIElement) throws {
        let alreadyFocused = boolAttribute(
            element,
            kAXFocusedAttribute as CFString
        ) ?? false
        if !alreadyFocused, let point = center(of: element) {
            click(at: point)
        }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            throw DriverError("Could not focus fixture element: \(result.rawValue)")
        }
        Thread.sleep(forTimeInterval: 0.4)
    }

    private static func typeText(_ text: String) {
        let characters = Array(text.utf16)
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        ) else {
            return
        }
        down.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: characters
        )
        up.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: characters
        )
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.25)
    }

    private static func pressKey(
        code: CGKeyCode,
        flags: CGEventFlags = []
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        if flags.contains(.maskCommand) {
            CGEvent(
                keyboardEventSource: source,
                virtualKey: 55,
                keyDown: true
            )?.post(tap: .cghidEventTap)
        }
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: code,
            keyDown: true
        )
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: code,
            keyDown: false
        )
        down?.flags = flags
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        if flags.contains(.maskCommand) {
            CGEvent(
                keyboardEventSource: source,
                virtualKey: 55,
                keyDown: false
            )?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    private static func drag(from source: CGPoint, to destination: CGPoint) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: source,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: source,
            mouseButton: .left
        )
        down?.setIntegerValueField(.mouseEventClickState, value: 0)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.15)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: destination,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.15)
        let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: destination,
            mouseButton: .left
        )
        up?.setIntegerValueField(.mouseEventClickState, value: 0)
        up?.post(tap: .cghidEventTap)
    }

    private static func click(at point: CGPoint) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        down?.setIntegerValueField(.mouseEventClickState, value: 0)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        up?.setIntegerValueField(.mouseEventClickState, value: 0)
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.2)
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        guard let positionValue = attribute(
            element,
            kAXPositionAttribute as CFString
        ), let sizeValue = attribute(
            element,
            kAXSizeAttribute as CFString
        ), CFGetTypeID(positionValue) == AXValueGetTypeID(),
           CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            positionValue as! AXValue,
            .cgPoint,
            &position
        ), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString)
            as? [AXUIElement] ?? []
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> Bool? {
        attribute(element, name) as? Bool
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success
        else {
            return nil
        }
        return value
    }
}

struct DriverError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
