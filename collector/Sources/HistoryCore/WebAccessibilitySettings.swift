import Foundation

/// Whether the recorder asks Chromium and Electron apps to build their web
/// accessibility tree.
///
/// Chromium and Electron keep that tree only while an assistive client asks
/// for it, and keeping it costs the app CPU and energy on every DOM change for
/// as long as the mode stays on (measured: about +51 mW in a busy Chrome tab,
/// about +21 mW in an Electron chat app). The default is `off`: the recorder
/// never sets `AXManualAccessibility` or `AXEnhancedUserInterface`, and web
/// pages contribute only what their app exposes anyway. `manual` sets
/// `AXManualAccessibility` (never `AXEnhancedUserInterface`) on activation of
/// the listed apps, or of every observed app when the list is empty, and
/// clears it again when recording pauses or stops.
///
/// In `config.json` this is either a string (`"off"` or `"manual"`) or an
/// object `{"mode": "manual", "bundleIdentifiers": [...]}`.
public struct WebAccessibilitySettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case off
        case manual
    }

    public var mode: Mode
    /// Apps that may be switched into web accessibility mode. Empty means
    /// every observed app (only Chromium and Electron react to it).
    public var bundleIdentifiers: [String]

    public init(mode: Mode = .off, bundleIdentifiers: [String] = []) {
        self.mode = mode
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func requestsAccessibility(for bundleIdentifier: String?) -> Bool {
        guard mode == .manual else {
            return false
        }
        if bundleIdentifiers.isEmpty {
            return true
        }
        guard let bundleIdentifier else {
            return false
        }
        return bundleIdentifiers.contains(bundleIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case bundleIdentifiers
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let mode = try? single.decode(Mode.self)
        {
            self.init(mode: mode)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .off,
            bundleIdentifiers: try container.decodeIfPresent(
                [String].self,
                forKey: .bundleIdentifiers
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
    }
}
