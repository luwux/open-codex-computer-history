import Foundation

/// Opt-in page text from a Chromium browser's DevTools protocol (CDP).
///
/// Off by default. When `source` is `cdp` and the frontmost app is listed in
/// `bundleIdentifiers`, a page whose URL stayed the same for `dwellSeconds`
/// (and was not read in the last `recaptureMinutes`) is read once: the
/// recorder lists the targets at `http://127.0.0.1:<port>/json/list`, opens a
/// WebSocket to the one page target whose URL matches, sends a single
/// read-only `Runtime.evaluate`, and closes the socket. It never navigates,
/// focuses, clicks, emulates, or stays attached. The browser must have been
/// started with `--remote-debugging-port=<port>` by the user; list only the
/// browser that owns the port.
///
/// Optional in `config.json` under `"pageText"`.
public struct PageTextSettings: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case off
        case cdp
    }

    public var source: Source
    /// Loopback port of the browser's remote debugging endpoint.
    public var port: Int
    /// Browsers whose pages may be read. Must name the browser that serves
    /// `port`; empty means none.
    public var bundleIdentifiers: [String]
    /// Seconds a page's URL must stay unchanged before it is read.
    public var dwellSeconds: Double
    /// Upper bound on characters recorded per page.
    public var maxCharacters: Int
    /// A URL read once is not read again for this many minutes.
    public var recaptureMinutes: Double
    /// Budget for the whole read (target list, connect, evaluate); capped at
    /// two seconds.
    public var timeoutMilliseconds: Double

    public init(
        source: Source = .off,
        port: Int = 9222,
        bundleIdentifiers: [String] = [],
        dwellSeconds: Double = 5,
        maxCharacters: Int = 8000,
        recaptureMinutes: Double = 30,
        timeoutMilliseconds: Double = 2000
    ) {
        self.source = source
        self.port = port
        self.bundleIdentifiers = bundleIdentifiers
        self.dwellSeconds = dwellSeconds
        self.maxCharacters = maxCharacters
        self.recaptureMinutes = recaptureMinutes
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public var isEnabled: Bool {
        source == .cdp && !bundleIdentifiers.isEmpty && (1...65535).contains(port)
    }

    public func applies(to bundleIdentifier: String?) -> Bool {
        guard isEnabled, let bundleIdentifier else {
            return false
        }
        return bundleIdentifiers.contains(bundleIdentifier)
    }

    public var effectiveDwellSeconds: TimeInterval {
        max(dwellSeconds, 1)
    }

    public var effectiveMaxCharacters: Int {
        min(max(maxCharacters, 1), 100_000)
    }

    public var effectiveRecaptureSeconds: TimeInterval {
        max(recaptureMinutes, 0) * 60
    }

    public var effectiveTimeout: TimeInterval {
        min(max(timeoutMilliseconds, 100), 2000) / 1000
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case port
        case bundleIdentifiers
        case dwellSeconds
        case maxCharacters
        case recaptureMinutes
        case timeoutMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let defaults = PageTextSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(Source.self, forKey: .source)
            ?? defaults.source
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        bundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .bundleIdentifiers
        ) ?? defaults.bundleIdentifiers
        dwellSeconds = try container.decodeIfPresent(Double.self, forKey: .dwellSeconds)
            ?? defaults.dwellSeconds
        maxCharacters = try container.decodeIfPresent(Int.self, forKey: .maxCharacters)
            ?? defaults.maxCharacters
        recaptureMinutes = try container.decodeIfPresent(
            Double.self,
            forKey: .recaptureMinutes
        ) ?? defaults.recaptureMinutes
        timeoutMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .timeoutMilliseconds
        ) ?? defaults.timeoutMilliseconds
    }
}

extension WebURL {
    /// Comparison key for a page URL: `http`/`https` only, scheme and host
    /// lowercased, default port and fragment dropped, empty path as `/`.
    /// The query is kept (it usually selects content).
    public static func matchKey(_ value: String?) -> String? {
        guard let value = webURL(value),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        components.user = nil
        components.password = nil
        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443)
        {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.string
    }
}

/// One entry of `/json/list`.
public struct CDPTarget: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let url: String
    public let title: String?
    public let webSocketDebuggerUrl: String?

    public init(
        id: String,
        type: String,
        url: String,
        title: String?,
        webSocketDebuggerUrl: String?
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.title = title
        self.webSocketDebuggerUrl = webSocketDebuggerUrl
    }

    public static func decodeList(_ data: Data) throws -> [CDPTarget] {
        try JSONDecoder().decode([CDPTarget].self, from: data)
    }
}

public enum CDPTargetMatcher {
    /// The page target showing `pageURL`, preferring one whose title also
    /// matches, whose debugger socket is on the loopback `port`. `nil` when
    /// no page matches exactly: the reader never guesses.
    public static func select(
        _ targets: [CDPTarget],
        pageURL: String?,
        title: String?,
        port: Int
    ) -> (target: CDPTarget, socketURL: URL)? {
        guard let key = WebURL.matchKey(pageURL) else {
            return nil
        }
        let matches = targets.compactMap { target -> (CDPTarget, URL)? in
            guard target.type == "page",
                  WebURL.matchKey(target.url) == key,
                  let socketURL = loopbackSocketURL(target.webSocketDebuggerUrl, port: port)
            else {
                return nil
            }
            return (target, socketURL)
        }
        if let title, let titled = matches.first(where: { $0.0.title == title }) {
            return titled
        }
        return matches.first
    }

    /// The debugger socket URL if it is `ws://` on a loopback host at
    /// `port` under `/devtools/page/`; anything else is refused.
    public static func loopbackSocketURL(_ value: String?, port: Int) -> URL? {
        guard let value,
              let components = URLComponents(string: value),
              components.scheme == "ws",
              let host = components.host,
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              components.port == port,
              components.path.hasPrefix("/devtools/page/")
        else {
            return nil
        }
        return components.url
    }
}

/// What one page read returns.
public struct PageTextResult: Equatable, Sendable {
    public let url: String
    public let title: String?
    /// Which element the text came from: `article`, `main`, `[role="main"]`,
    /// or `body`.
    public let element: String?
    /// Length of the element's full text before truncation.
    public let length: Int
    public let text: String

    public init(url: String, title: String?, element: String?, length: Int, text: String) {
        self.url = url
        self.title = title
        self.element = element
        self.length = length
        self.text = text
    }
}

/// The only message the page-text reader sends, and its reply parsing.
public enum CDPPageText {
    /// Every CDP method the reader may send. Nothing that changes a page, its
    /// focus or visibility (`Emulation.*`, `Page.*`, `Input.*`, `Target.*`),
    /// and no domain is enabled, so no events are streamed back.
    public static let methods: Set<String> = ["Runtime.evaluate"]

    /// Main content first: the first of `article`, `main`, `[role="main"]`
    /// with at least `minimumMainCharacters` of text, else `document.body`.
    public static func expression(maxCharacters: Int, minimumMainCharacters: Int = 200) -> String {
        """
        (() => {
          const max = \(max(maxCharacters, 1)), min = \(max(minimumMainCharacters, 0));
          let element = null, text = '';
          for (const selector of ['article', 'main', '[role="main"]']) {
            const node = document.querySelector(selector);
            const value = node ? (node.innerText || '') : '';
            if (value.trim().length >= min) { element = selector; text = value; break; }
          }
          if (element === null && document.body) {
            element = 'body'; text = document.body.innerText || '';
          }
          return { url: location.href, title: document.title, element,
                   length: text.length, text: text.slice(0, max) };
        })()
        """
    }

    /// The `Runtime.evaluate` request. The value is returned by value; no
    /// user gesture, no command-line API, exceptions not reported to the
    /// page's console.
    public static func evaluateMessage(id: Int, maxCharacters: Int) -> [String: Any] {
        [
            "id": id,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression(maxCharacters: maxCharacters),
                "returnByValue": true,
                "awaitPromise": false,
                "userGesture": false,
                "includeCommandLineAPI": false,
                "silent": true,
            ] as [String: Any],
        ]
    }

    public static func evaluateMessageData(id: Int, maxCharacters: Int) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: evaluateMessage(id: id, maxCharacters: maxCharacters)
        )
    }

    public enum ReplyError: Error, Equatable {
        case notReply
        case protocolError(String)
        case exception(String)
        case malformed
    }

    /// Parses a WebSocket message. Returns `nil` for messages that are not
    /// the reply to `id` (events or other replies), which the reader skips.
    public static func parseReply(
        _ data: Data,
        id: Int,
        maxCharacters: Int
    ) -> Result<PageTextResult, ReplyError>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformed)
        }
        guard let replyID = object["id"] as? Int, replyID == id else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            return .failure(.protocolError(error["message"] as? String ?? "error"))
        }
        guard let result = object["result"] as? [String: Any] else {
            return .failure(.malformed)
        }
        if let details = result["exceptionDetails"] as? [String: Any] {
            return .failure(.exception(details["text"] as? String ?? "exception"))
        }
        guard let remote = result["result"] as? [String: Any],
              let value = remote["value"] as? [String: Any],
              let url = value["url"] as? String
        else {
            return .failure(.malformed)
        }
        let text = cleaned(value["text"] as? String ?? "", maxCharacters: maxCharacters)
        return .success(PageTextResult(
            url: url,
            title: (value["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            element: value["element"] as? String,
            length: value["length"] as? Int ?? text.count,
            text: text
        ))
    }

    /// Trims lines, drops runs of blank lines to one, and truncates.
    public static func cleaned(_ text: String, maxCharacters: Int) -> String {
        var lines: [Substring] = []
        var blank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !blank, !lines.isEmpty {
                    lines.append("")
                }
                blank = true
                continue
            }
            blank = false
            lines.append(Substring(trimmed))
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return String(lines.joined(separator: "\n").prefix(max(maxCharacters, 0)))
    }
}

/// Decides when a page has been looked at long enough to read, and keeps a
/// URL from being read again within the recapture interval.
///
/// The recorder reports the frontmost page on every context read it already
/// does (window changes, title changes, typing, clicks); `observe` costs no
/// requests. A read is due once the same candidate has been current for the
/// dwell time.
public struct PageTextDwellTracker: Sendable {
    public struct Candidate: Equatable, Sendable {
        public let bundleIdentifier: String
        public let windowKey: String
        /// `WebURL.matchKey` of the page URL.
        public let urlKey: String

        public init(bundleIdentifier: String, windowKey: String, urlKey: String) {
            self.bundleIdentifier = bundleIdentifier
            self.windowKey = windowKey
            self.urlKey = urlKey
        }
    }

    public var dwellSeconds: TimeInterval
    public var recaptureSeconds: TimeInterval
    public private(set) var current: Candidate?
    private var since: Date?
    private var attempts: [String: Date] = [:]

    public init(dwellSeconds: TimeInterval, recaptureSeconds: TimeInterval) {
        self.dwellSeconds = dwellSeconds
        self.recaptureSeconds = recaptureSeconds
    }

    /// Records the frontmost page (or `nil` for none). When it changed and
    /// may need a read, returns when that read becomes due.
    public mutating func observe(_ candidate: Candidate?, now: Date) -> Date? {
        guard candidate != current else {
            return nil
        }
        current = candidate
        since = candidate == nil ? nil : now
        guard let candidate, !wasAttempted(candidate.urlKey, now: now) else {
            return nil
        }
        return now.addingTimeInterval(dwellSeconds)
    }

    /// The current candidate if it has been current for the dwell time and
    /// its URL was not read within the recapture interval.
    public func due(now: Date) -> Candidate? {
        guard let current, let since,
              now.timeIntervalSince(since) >= dwellSeconds - 0.05,
              !wasAttempted(current.urlKey, now: now)
        else {
            return nil
        }
        return current
    }

    /// Marks a URL as read (successfully or not) at `now`.
    public mutating func recordAttempt(_ urlKey: String, now: Date) {
        attempts[urlKey] = now
        if attempts.count > 512 {
            attempts = attempts.filter { now.timeIntervalSince($0.value) < recaptureSeconds }
        }
    }

    public func wasAttempted(_ urlKey: String, now: Date) -> Bool {
        guard let last = attempts[urlKey] else {
            return false
        }
        return now.timeIntervalSince(last) < recaptureSeconds
    }
}

public enum PageTextEligibility {
    /// Why a page must not be read, or `nil` when it may be. Reading is
    /// refused for unlisted apps, non-web URLs, when text capture is off,
    /// when the policy suppresses the window (app or URL rules, private
    /// browsing, a focused password field), and while any app holds secure
    /// keyboard input.
    public static func refusal(
        settings: PageTextSettings,
        captureText: Bool,
        bundleIdentifier: String?,
        url: String?,
        suppressionReason: String?,
        secureInput: Bool,
        secureEventInput: Bool
    ) -> String? {
        guard settings.applies(to: bundleIdentifier) else {
            return "not_enabled"
        }
        guard captureText else {
            return "capture_text_off"
        }
        guard WebURL.matchKey(url) != nil else {
            return "not_web_page"
        }
        if let suppressionReason {
            return suppressionReason
        }
        if secureInput || secureEventInput {
            return "secure_input"
        }
        return nil
    }
}
