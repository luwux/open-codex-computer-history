import Foundation

/// Reading the active tab's URL and title through the browser's scripting
/// dictionary (Apple Events).
///
/// This needs no accessibility tree from the page, so it works while
/// Chromium and Electron keep their web accessibility mode off. It costs the
/// browser one Apple Event per property (median 33 ms for URL and title in
/// Dia) and is done only when a browser window becomes frontmost or its title
/// changes. It needs the Automation permission for each browser; macOS asks
/// once, and a denial falls back to the accessibility-based lookup.
///
/// Optional in `config.json` under `"browserScripting"`.
public struct BrowserScriptingSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Timeout for one Apple Event. The recorder falls back to the
    /// accessibility lookup and pauses scripting that browser for a minute
    /// when it is exceeded.
    public var timeoutMilliseconds: Double
    /// A cached tab for an unchanged window title is re-read after this many
    /// seconds, so navigations that keep the title are picked up.
    public var refreshSeconds: Double
    /// Browsers never sent Apple Events, even if their dictionary is known.
    public var excludedBundleIdentifiers: [String]

    public init(
        enabled: Bool = true,
        timeoutMilliseconds: Double = 500,
        refreshSeconds: Double = 30,
        excludedBundleIdentifiers: [String] = []
    ) {
        self.enabled = enabled
        self.timeoutMilliseconds = timeoutMilliseconds
        self.refreshSeconds = refreshSeconds
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    /// The scripting dictionary to use for an app, or `nil` when scripting
    /// is off, the app is excluded, or it is not a known scriptable browser.
    public func browser(for bundleIdentifier: String?) -> ScriptableBrowser? {
        guard enabled,
              let bundleIdentifier,
              !excludedBundleIdentifiers.contains(bundleIdentifier)
        else {
            return nil
        }
        return ScriptableBrowser.known(bundleIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case timeoutMilliseconds
        case refreshSeconds
        case excludedBundleIdentifiers
    }

    public init(from decoder: Decoder) throws {
        let defaults = BrowserScriptingSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? defaults.enabled
        timeoutMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .timeoutMilliseconds
        ) ?? defaults.timeoutMilliseconds
        refreshSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .refreshSeconds
        ) ?? defaults.refreshSeconds
        excludedBundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedBundleIdentifiers
        ) ?? defaults.excludedBundleIdentifiers
    }
}

/// Four-character codes of one browser's scripting dictionary for
/// `URL`/`title`/`mode` of the active tab of the front window.
public struct ScriptableBrowser: Equatable, Sendable {
    /// Class code of `window` (`cwin` in most dictionaries; Arc uses `WiND`).
    public let windowClass: FourCharCode
    /// Property code of the window's active tab (`acTa`, Safari `cTab`).
    public let activeTabProperty: FourCharCode
    /// Property code of the tab's URL (`URL `, Safari `pURL`).
    public let urlProperty: FourCharCode
    /// Property code of the tab's title (`pnam` everywhere).
    public let titleProperty: FourCharCode
    /// Property code of the window's `mode` (`normal` or `incognito`), when
    /// the dictionary has one.
    public let modeProperty: FourCharCode?

    public init(
        windowClass: FourCharCode,
        activeTabProperty: FourCharCode,
        urlProperty: FourCharCode,
        titleProperty: FourCharCode,
        modeProperty: FourCharCode?
    ) {
        self.windowClass = windowClass
        self.activeTabProperty = activeTabProperty
        self.urlProperty = urlProperty
        self.titleProperty = titleProperty
        self.modeProperty = modeProperty
    }

    /// Chromium's `scripting.sdef`: Chrome, Chromium, Brave, Edge, Vivaldi.
    public static let chromium = ScriptableBrowser(
        windowClass: fourCharCode("cwin"),
        activeTabProperty: fourCharCode("acTa"),
        urlProperty: fourCharCode("URL "),
        titleProperty: fourCharCode("pnam"),
        modeProperty: fourCharCode("mode")
    )

    /// Dia's own dictionary: Chromium's terms, no window `mode`.
    public static let dia = ScriptableBrowser(
        windowClass: fourCharCode("cwin"),
        activeTabProperty: fourCharCode("acTa"),
        urlProperty: fourCharCode("URL "),
        titleProperty: fourCharCode("pnam"),
        modeProperty: nil
    )

    /// Arc: Chromium's terms with its own window class code.
    public static let arc = ScriptableBrowser(
        windowClass: fourCharCode("WiND"),
        activeTabProperty: fourCharCode("acTa"),
        urlProperty: fourCharCode("URL "),
        titleProperty: fourCharCode("pnam"),
        modeProperty: fourCharCode("mode")
    )

    /// Safari: `current tab`, `URL` (`pURL`), `name`. No private-window term.
    public static let safari = ScriptableBrowser(
        windowClass: fourCharCode("cwin"),
        activeTabProperty: fourCharCode("cTab"),
        urlProperty: fourCharCode("pURL"),
        titleProperty: fourCharCode("pnam"),
        modeProperty: nil
    )

    public static let knownBrowsers: [String: ScriptableBrowser] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.brave.Browser.nightly": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.microsoft.edgemac.Dev": .chromium,
        "com.microsoft.edgemac.Canary": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "company.thebrowser.dia": .dia,
        "company.thebrowser.Browser": .arc,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
    ]

    public static func known(_ bundleIdentifier: String) -> ScriptableBrowser? {
        knownBrowsers[bundleIdentifier]
    }
}

public func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.prefix(4).reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
}

/// The active tab as reported by the browser.
public struct BrowserTab: Equatable, Sendable {
    /// `http`/`https` URL, or `nil` for internal pages (new tab, settings).
    public let url: String?
    public let title: String?
    /// The window is an incognito/private window.
    public let isPrivate: Bool

    public init(url: String?, title: String?, isPrivate: Bool) {
        self.url = url
        self.title = title
        self.isPrivate = isPrivate
    }

    /// Builds a tab from raw property values, keeping only web URLs.
    public init(rawURL: String?, rawTitle: String?, mode: String?) {
        self.url = WebURL.webURL(rawURL)
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.isEmpty == false ? title : nil
        self.isPrivate = mode?.lowercased() == "incognito"
    }
}

/// Outcome of one Apple Event sent to a browser.
public enum AppleEventOutcome: Equatable, Sendable {
    /// The property's value; `nil` when it has none (no window, no tab).
    case value(String?)
    /// The user denied Automation for this browser (`errAEEventNotPermitted`).
    case notPermitted
    /// Automation was never decided and sending would prompt
    /// (`errAEEventWouldRequireUserConsent`).
    case needsConsent
    /// The browser did not answer in time (`errAETimeout`).
    case timedOut
    /// The browser is not running (`procNotFound`, `connectionInvalid`).
    case unavailable
    case failed(Int)

    public static let errAEEventNotPermitted = -1743
    public static let errAEEventWouldRequireUserConsent = -1744
    public static let errAETimeout = -1712
    public static let errAENoSuchObject = -1728
    public static let errAEReplyNotArrived = -1718
    public static let procNotFound = -600
    public static let connectionInvalid = -609

    /// Maps an OSStatus from sending or from the reply's `errn`.
    public init(status: Int) {
        switch status {
        case 0:
            self = .value(nil)
        case Self.errAEEventNotPermitted:
            self = .notPermitted
        case Self.errAEEventWouldRequireUserConsent:
            self = .needsConsent
        case Self.errAETimeout, Self.errAEReplyNotArrived:
            self = .timedOut
        case Self.procNotFound, Self.connectionInvalid:
            self = .unavailable
        case Self.errAENoSuchObject, -1719, -1700, -1708, -10000:
            // No such window/tab, bad index, can't coerce, not handled:
            // the property has no value right now.
            self = .value(nil)
        default:
            self = .failed(status)
        }
    }

    /// Parses a `getd` reply: an `errn` parameter means the browser
    /// reported an error; otherwise the direct object is the value.
    public init(reply: NSAppleEventDescriptor) {
        let keyErrorNumber = fourCharCode("errn")
        let keyDirectObject = fourCharCode("----")
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber),
           error.int32Value != 0
        {
            self.init(status: Int(error.int32Value))
            return
        }
        guard let value = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            self = .value(nil)
            return
        }
        if value.descriptorType == fourCharCode("msng") ||
            value.descriptorType == fourCharCode("null")
        {
            self = .value(nil)
            return
        }
        self = .value(value.stringValue)
    }

    public var string: String? {
        if case let .value(value) = self {
            return value
        }
        return nil
    }
}
