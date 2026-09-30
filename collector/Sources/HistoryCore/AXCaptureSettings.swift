import Foundation

/// Bounds on the accessibility work one recorded event may cost.
///
/// Every accessibility request is answered on the target application's main
/// thread, so these limits bound the CPU and energy the recorder spends in
/// other applications. All fields are optional in `config.json` under
/// `"axCapture"`; missing fields keep the defaults.
public struct AXCaptureSettings: Codable, Equatable, Sendable {
    /// Minimum seconds between two tree captures of the same window while its
    /// title and URL stay unchanged. Events inside the interval carry no `ax`
    /// payload; the next capture diffs against the last captured revision.
    public var minimumTreeIntervalSeconds: Double
    /// Wall-clock budget for one tree capture. Traversal stops when exceeded.
    public var treeTimeBudgetMilliseconds: Double
    /// Timeout for a single accessibility request (system default: 6 s).
    public var messagingTimeoutMilliseconds: Double
    /// Upper bound on children followed below one element.
    public var maximumChildrenPerElement: Int
    /// Container roles whose off-screen children are skipped, mapped to the
    /// attribute listing only the visible ones. Native tables and outlines
    /// materialize row views on demand for accessibility clients, so walking
    /// all rows of a long list (a mailbox, a file list) costs seconds.
    public var visibleChildrenAttributeByRole: [String: String]

    public static let defaultVisibleChildrenAttributeByRole: [String: String] = [
        "AXTable": "AXVisibleRows",
        "AXOutline": "AXVisibleRows",
        "AXList": "AXVisibleChildren",
        "AXGrid": "AXVisibleChildren",
    ]

    public init(
        minimumTreeIntervalSeconds: Double = 2,
        treeTimeBudgetMilliseconds: Double = 250,
        messagingTimeoutMilliseconds: Double = 250,
        maximumChildrenPerElement: Int = 200,
        visibleChildrenAttributeByRole: [String: String] =
            AXCaptureSettings.defaultVisibleChildrenAttributeByRole
    ) {
        self.minimumTreeIntervalSeconds = minimumTreeIntervalSeconds
        self.treeTimeBudgetMilliseconds = treeTimeBudgetMilliseconds
        self.messagingTimeoutMilliseconds = messagingTimeoutMilliseconds
        self.maximumChildrenPerElement = maximumChildrenPerElement
        self.visibleChildrenAttributeByRole = visibleChildrenAttributeByRole
    }

    private enum CodingKeys: String, CodingKey {
        case minimumTreeIntervalSeconds
        case treeTimeBudgetMilliseconds
        case messagingTimeoutMilliseconds
        case maximumChildrenPerElement
        case visibleChildrenAttributeByRole
    }

    public init(from decoder: Decoder) throws {
        let defaults = AXCaptureSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minimumTreeIntervalSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .minimumTreeIntervalSeconds
        ) ?? defaults.minimumTreeIntervalSeconds
        treeTimeBudgetMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .treeTimeBudgetMilliseconds
        ) ?? defaults.treeTimeBudgetMilliseconds
        messagingTimeoutMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .messagingTimeoutMilliseconds
        ) ?? defaults.messagingTimeoutMilliseconds
        maximumChildrenPerElement = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumChildrenPerElement
        ) ?? defaults.maximumChildrenPerElement
        visibleChildrenAttributeByRole = try container.decodeIfPresent(
            [String: String].self,
            forKey: .visibleChildrenAttributeByRole
        ) ?? defaults.visibleChildrenAttributeByRole
    }
}

/// Decides whether an event may pay for a fresh tree capture of a window.
///
/// A capture is taken when the window was never captured, its title or URL
/// changed, the caller forces one, or `minimumInterval` has elapsed since the
/// last capture. Skipped events carry no tree, so later diffs stay correct:
/// they compare against the last revision that was actually emitted.
public struct AXCaptureThrottle: Sendable {
    public var minimumInterval: TimeInterval
    private var lastCapture: [String: (context: String, at: Date)] = [:]

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    public func shouldCapture(
        windowKey: String?,
        context: String,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        guard !force, let windowKey, let last = lastCapture[windowKey] else {
            return true
        }
        return last.context != context || now.timeIntervalSince(last.at) >= minimumInterval
    }

    public mutating func recordCapture(windowKey: String?, context: String, at: Date = Date()) {
        guard let windowKey else {
            return
        }
        lastCapture[windowKey] = (context, at)
        if lastCapture.count > 256 {
            let cutoff = at.addingTimeInterval(-10 * 60)
            lastCapture = lastCapture.filter { $0.value.at > cutoff }
        }
    }

    public mutating func reset() {
        lastCapture.removeAll()
    }
}
