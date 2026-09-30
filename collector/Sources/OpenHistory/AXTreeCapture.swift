import ApplicationServices
import Foundation
import HistoryCore

enum AXTreeCapture {
    /// Attributes read for every traversed node, in one request per node.
    static let nodeAttributes: [CFString] = [
        kAXRoleAttribute as CFString,
        kAXSubroleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXPlaceholderValueAttribute as CFString,
        kAXIdentifierAttribute as CFString,
        kAXFocusedAttribute as CFString,
        kAXEnabledAttribute as CFString,
        kAXChildrenAttribute as CFString,
        "AXURL" as CFString,
    ]

    struct Result {
        let revision: AXTreeRevisionSnapshot
        /// The first web area rendered and its `AXURL`, if any.
        let webArea: AXUIElement?
        let webAreaURL: String?
    }

    /// Renders the window's accessibility tree, web content first.
    ///
    /// Browsers spend most nodes on their own chrome (tab sidebars, toolbars),
    /// so page content used to fall outside the node budget. Web areas are
    /// rendered first with a deeper limit; the remaining budget covers the
    /// window. Containers with no role-specific information are traversed but
    /// not rendered, and total traversal is bounded by node count, children
    /// per element, and wall-clock time to keep capture cheap for the target.
    static func capture(
        root: AXUIElement?,
        secureInput: Bool,
        settings: AXCaptureSettings = AXCaptureSettings(),
        maximumNodes: Int = 500,
        maximumDepth: Int = 14,
        webNodeBudget: Int = 380,
        webMaximumDepth: Int = 28,
        traversalLimit: Int = 2_500
    ) -> Result? {
        guard let root else {
            return nil
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(settings.treeTimeBudgetMilliseconds, 1) * 1_000_000)
        var reader = NodeReader(settings: settings, deadline: deadline)
        var lines: [Int: String] = [:]
        var visited = Set<AXElementKey>()
        var nextID = 0
        var traversed = 0
        var webArea: AXUIElement?
        var webAreaURL: String?

        func visit(_ element: AXUIElement, depth: Int, maxDepth: Int, nodeLimit: Int) {
            guard nextID < nodeLimit, depth <= maxDepth, traversed < traversalLimit,
                  !reader.expired
            else {
                return
            }
            guard visited.insert(AXElementKey(element: element)).inserted,
                  let node = reader.node(element)
            else {
                return
            }
            traversed += 1
            if node.role == "AXWebArea", webArea == nil {
                webArea = element
                webAreaURL = node.url
            }
            if let line = render(node, depth: depth, secureInput: secureInput) {
                lines[nextID] = line
                nextID += 1
            }
            for child in node.children {
                visit(child, depth: depth + 1, maxDepth: maxDepth, nodeLimit: nodeLimit)
            }
        }

        for webArea in webAreas(under: root, reader: &reader) {
            visit(
                webArea,
                depth: 0,
                maxDepth: webMaximumDepth,
                nodeLimit: min(maximumNodes, nextID + webNodeBudget)
            )
        }
        visit(root, depth: 0, maxDepth: maximumDepth, nodeLimit: maximumNodes)
        return Result(
            revision: AXTreeRevisionSnapshot(lines: lines),
            webArea: webArea,
            webAreaURL: webAreaURL
        )
    }

    /// Whether the window exposes any web area (used to decide whether a
    /// Chromium browser needs `AXEnhancedUserInterface`).
    static func hasWebArea(under root: AXUIElement) -> Bool {
        var reader = NodeReader(
            settings: AXCaptureSettings(),
            deadline: DispatchTime.now().uptimeNanoseconds + 250_000_000
        )
        return !webAreas(under: root, reader: &reader).isEmpty
    }

    /// Breadth-first search for web areas near the top of a window. Nodes
    /// read here are cached by `reader`, so the render pass does not read
    /// them again.
    private static func webAreas(
        under root: AXUIElement,
        reader: inout NodeReader,
        searchLimit: Int = 300
    ) -> [AXUIElement] {
        var queue = [root]
        var found: [AXUIElement] = []
        var index = 0
        while index < queue.count, index < searchLimit, !reader.expired {
            let element = queue[index]
            index += 1
            guard let node = reader.node(element) else {
                continue
            }
            if node.role == "AXWebArea" {
                found.append(element)
                continue
            }
            queue.append(contentsOf: node.children)
        }
        return found
    }

    struct Node {
        let role: String
        let values: AXAttributeValues
        let children: [AXUIElement]

        var url: String? {
            values.string("AXURL" as CFString)
        }
    }

    /// Reads each node once with a batched request and caches the result.
    struct NodeReader {
        let settings: AXCaptureSettings
        let deadline: UInt64
        private var cache: [AXElementKey: Node] = [:]

        init(settings: AXCaptureSettings, deadline: UInt64) {
            self.settings = settings
            self.deadline = deadline
        }

        var expired: Bool {
            DispatchTime.now().uptimeNanoseconds >= deadline
        }

        mutating func node(_ element: AXUIElement) -> Node? {
            let key = AXElementKey(element: element)
            if let cached = cache[key] {
                return cached
            }
            guard !expired else {
                return nil
            }
            let values = AXAttributeValues(element, nodeAttributes)
            let role = values.string(kAXRoleAttribute as CFString) ?? "AXUnknown"
            var children = values.elements(kAXChildrenAttribute as CFString) ?? []
            if !children.isEmpty,
               let visibleAttribute = settings.visibleChildrenAttributeByRole[role],
               let visible = axCopyAttribute(element, visibleAttribute as CFString)
                   as? [AXUIElement]
            {
                children = visible
            }
            if children.count > settings.maximumChildrenPerElement {
                children = Array(children.prefix(settings.maximumChildrenPerElement))
            }
            let node = Node(role: role, values: values, children: children)
            cache[key] = node
            return node
        }
    }

    private static func render(
        _ node: Node,
        depth: Int,
        secureInput: Bool
    ) -> String? {
        let role = node.role
        let values = node.values
        var attributes: [String] = []
        if role == "AXWebArea" {
            append("url", node.url, to: &attributes)
        }
        append("subrole", values.string(kAXSubroleAttribute as CFString), to: &attributes)
        append("title", values.string(kAXTitleAttribute as CFString), to: &attributes)
        append(
            "description",
            values.string(kAXDescriptionAttribute as CFString),
            to: &attributes
        )
        if !secureInput && role != "AXSecureTextField" {
            append("value", values.string(kAXValueAttribute as CFString), to: &attributes)
        }
        append(
            "placeholder",
            values.string(kAXPlaceholderValueAttribute as CFString),
            to: &attributes
        )
        append(
            "identifier",
            values.string(kAXIdentifierAttribute as CFString),
            to: &attributes
        )
        if let focused = values.bool(kAXFocusedAttribute as CFString), focused {
            attributes.append("focused=true")
        }
        if let enabled = values.bool(kAXEnabledAttribute as CFString), !enabled {
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
}
