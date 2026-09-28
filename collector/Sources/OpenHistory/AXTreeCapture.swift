import ApplicationServices
import Foundation
import HistoryCore

enum AXTreeCapture {
    /// Renders the window's accessibility tree, web content first.
    ///
    /// Browsers spend most nodes on their own chrome (tab sidebars, toolbars),
    /// so page content used to fall outside the node budget. Web areas are
    /// rendered first with a deeper limit; the remaining budget covers the
    /// window. Containers with no role-specific information are traversed but
    /// not rendered, and total traversal is bounded to keep capture cheap.
    static func capture(
        root: AXUIElement?,
        secureInput: Bool,
        maximumNodes: Int = 500,
        maximumDepth: Int = 14,
        webNodeBudget: Int = 380,
        webMaximumDepth: Int = 28,
        traversalLimit: Int = 2_500
    ) -> AXTreeRevisionSnapshot? {
        guard let root else {
            return nil
        }
        var lines: [Int: String] = [:]
        var visited = Set<CFHashCode>()
        var nextID = 0
        var traversed = 0

        func visit(_ element: AXUIElement, depth: Int, maxDepth: Int, nodeLimit: Int) {
            guard nextID < nodeLimit, depth <= maxDepth, traversed < traversalLimit else {
                return
            }
            guard visited.insert(CFHash(element)).inserted else {
                return
            }
            traversed += 1
            if let line = render(element, depth: depth, secureInput: secureInput) {
                lines[nextID] = line
                nextID += 1
            }
            for child in children(element) {
                visit(child, depth: depth + 1, maxDepth: maxDepth, nodeLimit: nodeLimit)
            }
        }

        for webArea in webAreas(under: root) {
            visit(
                webArea,
                depth: 0,
                maxDepth: webMaximumDepth,
                nodeLimit: min(maximumNodes, nextID + webNodeBudget)
            )
        }
        visit(root, depth: 0, maxDepth: maximumDepth, nodeLimit: maximumNodes)
        return AXTreeRevisionSnapshot(lines: lines)
    }

    /// Breadth-first search for web areas near the top of a window.
    static func webAreas(under root: AXUIElement, searchLimit: Int = 300) -> [AXUIElement] {
        var queue = [root]
        var found: [AXUIElement] = []
        var index = 0
        while index < queue.count, index < searchLimit {
            let element = queue[index]
            index += 1
            if stringAttribute(element, kAXRoleAttribute as CFString) == "AXWebArea" {
                found.append(element)
                continue
            }
            queue.append(contentsOf: children(element))
        }
        return found
    }

    private static func render(
        _ element: AXUIElement,
        depth: Int,
        secureInput: Bool
    ) -> String? {
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "AXUnknown"
        var attributes: [String] = []
        if role == "AXWebArea" {
            append("url", stringAttribute(element, "AXURL" as CFString), to: &attributes)
        }
        append("subrole", stringAttribute(element, kAXSubroleAttribute as CFString), to: &attributes)
        append("title", stringAttribute(element, kAXTitleAttribute as CFString), to: &attributes)
        append(
            "description",
            stringAttribute(element, kAXDescriptionAttribute as CFString),
            to: &attributes
        )
        if !secureInput && role != "AXSecureTextField" {
            append("value", stringAttribute(element, kAXValueAttribute as CFString), to: &attributes)
        }
        append(
            "placeholder",
            stringAttribute(element, kAXPlaceholderValueAttribute as CFString),
            to: &attributes
        )
        append(
            "identifier",
            stringAttribute(element, kAXIdentifierAttribute as CFString),
            to: &attributes
        )
        if let focused = boolAttribute(element, kAXFocusedAttribute as CFString), focused {
            attributes.append("focused=true")
        }
        if let enabled = boolAttribute(element, kAXEnabledAttribute as CFString), !enabled {
            attributes.append("enabled=false")
        }
        if attributes.isEmpty, ObservationPolicy.isStructuralContainer(role: role) {
            return nil
        }
        let indentation = String(repeating: "  ", count: depth)
        return attributes.isEmpty
            ? "\(indentation)\(role)"
            : "\(indentation)\(role) \(attributes.joined(separator: " "))"
    }

    private static func append(
        _ name: String,
        _ value: String?,
        to attributes: inout [String]
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return
        }
        let normalized = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .prefix(500)
        attributes.append("\(name)=\"\(normalized)\"")
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return nil
    }

    private static func boolAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value as? Bool
    }
}
