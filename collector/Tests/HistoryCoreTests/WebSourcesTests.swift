import Foundation
import XCTest
@testable import HistoryCore

final class WebSourceSettingsTests: XCTestCase {
    func testDefaultsDoNotForceAccessibilityModeOrReadPageText() throws {
        for policy in [
            ObservationPolicy(),
            try JSONDecoder().decode(ObservationPolicy.self, from: Data("{}".utf8)),
        ] {
            XCTAssertEqual(policy.webAccessibility.mode, .off)
            XCTAssertFalse(policy.webAccessibility.requestsAccessibility(for: "com.google.Chrome"))
            XCTAssertFalse(policy.webAccessibility.requestsAccessibility(for: nil))
            XCTAssertEqual(policy.pageText.source, .off)
            XCTAssertFalse(policy.pageText.isEnabled)
            XCTAssertFalse(policy.pageText.applies(to: "company.thebrowser.dia"))
            XCTAssertTrue(policy.browserScripting.enabled)
        }
    }

    func testWebAccessibilityDecodesStringOrObject() throws {
        let manual = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"webAccessibility": "manual"}"#.utf8)
        )
        XCTAssertEqual(manual.webAccessibility, WebAccessibilitySettings(mode: .manual))
        XCTAssertTrue(manual.webAccessibility.requestsAccessibility(for: "any.app"))

        let listed = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"webAccessibility": {"mode": "manual", "bundleIdentifiers": ["a.b"]}}"#.utf8)
        )
        XCTAssertTrue(listed.webAccessibility.requestsAccessibility(for: "a.b"))
        XCTAssertFalse(listed.webAccessibility.requestsAccessibility(for: "c.d"))
        XCTAssertFalse(listed.webAccessibility.requestsAccessibility(for: nil))

        let off = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"webAccessibility": {"bundleIdentifiers": ["a.b"]}}"#.utf8)
        )
        XCTAssertFalse(off.webAccessibility.requestsAccessibility(for: "a.b"))

        XCTAssertThrowsError(try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"webAccessibility": "always"}"#.utf8)
        ))
    }

    func testPageTextNeedsSourceAndBrowserListAndIsBounded() throws {
        let partial = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"pageText": {"source": "cdp"}}"#.utf8)
        )
        XCTAssertFalse(partial.pageText.isEnabled, "no browser listed reads nothing")
        XCTAssertEqual(partial.pageText.port, 9222)
        XCTAssertEqual(partial.pageText.dwellSeconds, 5)
        XCTAssertEqual(partial.pageText.maxCharacters, 8000)

        let enabled = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"""
            {"pageText": {"source": "cdp", "port": 9333, "bundleIdentifiers": ["x.browser"],
              "maxCharacters": 10000000, "timeoutMilliseconds": 60000, "dwellSeconds": 0}}
            """#.utf8)
        )
        XCTAssertTrue(enabled.pageText.applies(to: "x.browser"))
        XCTAssertFalse(enabled.pageText.applies(to: "y.browser"))
        XCTAssertEqual(enabled.pageText.port, 9333)
        XCTAssertEqual(enabled.pageText.effectiveTimeout, 2)
        XCTAssertEqual(enabled.pageText.effectiveMaxCharacters, 100_000)
        XCTAssertEqual(enabled.pageText.effectiveDwellSeconds, 1)

        var badPort = enabled.pageText
        badPort.port = 70000
        XCTAssertFalse(badPort.isEnabled)
    }

    func testPolicyRoundTripsWebSources() throws {
        var policy = ObservationPolicy()
        policy.webAccessibility = WebAccessibilitySettings(mode: .manual, bundleIdentifiers: ["a.b"])
        policy.browserScripting.excludedBundleIdentifiers = ["com.apple.Safari"]
        policy.pageText = PageTextSettings(source: .cdp, bundleIdentifiers: ["x.browser"])
        let decoded = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: JSONEncoder().encode(policy)
        )
        XCTAssertEqual(decoded, policy)
    }
}

final class BrowserScriptingTests: XCTestCase {
    func testKnownDictionariesUseEachBrowsersTerms() {
        let settings = BrowserScriptingSettings()
        let chrome = settings.browser(for: "com.google.Chrome")
        XCTAssertEqual(chrome, .chromium)
        XCTAssertEqual(chrome?.activeTabProperty, fourCharCode("acTa"))
        XCTAssertEqual(chrome?.urlProperty, fourCharCode("URL "))
        XCTAssertEqual(chrome?.modeProperty, fourCharCode("mode"))
        XCTAssertEqual(settings.browser(for: "com.brave.Browser"), .chromium)

        let dia = settings.browser(for: "company.thebrowser.dia")
        XCTAssertEqual(dia?.windowClass, fourCharCode("cwin"))
        XCTAssertNil(dia?.modeProperty)

        XCTAssertEqual(settings.browser(for: "company.thebrowser.Browser")?.windowClass, fourCharCode("WiND"))

        let safari = settings.browser(for: "com.apple.Safari")
        XCTAssertEqual(safari?.activeTabProperty, fourCharCode("cTab"))
        XCTAssertEqual(safari?.urlProperty, fourCharCode("pURL"))

        XCTAssertNil(settings.browser(for: "org.mozilla.firefox"))
        XCTAssertNil(settings.browser(for: "com.anthropic.claudefordesktop"))
        XCTAssertNil(settings.browser(for: nil))
    }

    func testDisabledOrExcludedBrowsersAreNotScripted() {
        XCTAssertNil(BrowserScriptingSettings(enabled: false).browser(for: "com.google.Chrome"))
        let excluded = BrowserScriptingSettings(excludedBundleIdentifiers: ["com.google.Chrome"])
        XCTAssertNil(excluded.browser(for: "com.google.Chrome"))
        XCTAssertNotNil(excluded.browser(for: "com.apple.Safari"))
    }

    func testFourCharCode() {
        XCTAssertEqual(fourCharCode("acTa"), 0x6163_5461)
        XCTAssertEqual(fourCharCode("URL "), 0x5552_4C20)
    }

    private func reply(_ configure: (NSAppleEventDescriptor) -> Void) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCharCode("aevt"),
            eventID: fourCharCode("ansr"),
            targetDescriptor: nil,
            returnID: -1,
            transactionID: 0
        )
        configure(reply)
        return reply
    }

    func testReplyParsing() {
        let value = reply {
            $0.setParam(NSAppleEventDescriptor(string: "https://example.com/"), forKeyword: fourCharCode("----"))
        }
        XCTAssertEqual(AppleEventOutcome(reply: value), .value("https://example.com/"))

        let denied = reply {
            $0.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: fourCharCode("errn"))
        }
        XCTAssertEqual(AppleEventOutcome(reply: denied), .notPermitted)

        let noWindow = reply {
            $0.setParam(NSAppleEventDescriptor(int32: -1728), forKeyword: fourCharCode("errn"))
        }
        XCTAssertEqual(AppleEventOutcome(reply: noWindow), .value(nil))

        XCTAssertEqual(AppleEventOutcome(reply: reply { _ in }), .value(nil))
        let missing = reply {
            $0.setParam(NSAppleEventDescriptor(typeCode: fourCharCode("msng")), forKeyword: fourCharCode("----"))
        }
        XCTAssertEqual(AppleEventOutcome(reply: missing).string, nil)
    }

    func testStatusMapping() {
        XCTAssertEqual(AppleEventOutcome(status: 0), .value(nil))
        XCTAssertEqual(AppleEventOutcome(status: -1743), .notPermitted)
        XCTAssertEqual(AppleEventOutcome(status: -1744), .needsConsent)
        XCTAssertEqual(AppleEventOutcome(status: -1712), .timedOut)
        XCTAssertEqual(AppleEventOutcome(status: -600), .unavailable)
        XCTAssertEqual(AppleEventOutcome(status: -1728), .value(nil))
        XCTAssertEqual(AppleEventOutcome(status: -50), .failed(-50))
    }

    func testTabKeepsOnlyWebURLsAndDetectsIncognito() {
        let tab = BrowserTab(rawURL: "https://example.com/a", rawTitle: "  Example ", mode: "normal")
        XCTAssertEqual(tab, BrowserTab(url: "https://example.com/a", title: "Example", isPrivate: false))

        let newTab = BrowserTab(rawURL: "chrome://newtab/", rawTitle: "", mode: "incognito")
        XCTAssertNil(newTab.url)
        XCTAssertNil(newTab.title)
        XCTAssertTrue(newTab.isPrivate)
        XCTAssertFalse(BrowserTab(rawURL: nil, rawTitle: nil, mode: nil).isPrivate)
    }

    func testPrivateWindowIsSuppressedWhateverItsTitle() {
        XCTAssertEqual(
            ObservationPolicy().shouldSuppress(
                bundleIdentifier: "com.google.Chrome",
                windowTitle: "Example Domain",
                urlDomain: "example.com",
                role: nil,
                subrole: nil,
                privateWindow: true
            ),
            "private_browsing"
        )
    }
}

final class PageTextTests: XCTestCase {
    func testMatchKeyNormalizesURLs() {
        XCTAssertEqual(
            WebURL.matchKey("HTTPS://User:pw@Example.COM:443/a?b=1#section"),
            "https://example.com/a?b=1"
        )
        XCTAssertEqual(WebURL.matchKey("http://example.com"), "http://example.com/")
        XCTAssertEqual(WebURL.matchKey("http://example.com:8080/x"), "http://example.com:8080/x")
        XCTAssertNotEqual(WebURL.matchKey("https://a.com/?q=1"), WebURL.matchKey("https://a.com/?q=2"))
        XCTAssertNil(WebURL.matchKey("chrome://settings"))
        XCTAssertNil(WebURL.matchKey("file:///etc/hosts"))
        XCTAssertNil(WebURL.matchKey(nil))
    }

    private let targetsJSON = #"""
    [
      {"id": "F1", "type": "iframe", "url": "https://example.com/a", "title": "frame",
       "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/F1"},
      {"id": "P1", "type": "page", "url": "https://example.com/a#top", "title": "Other",
       "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/P1", "faviconUrl": "x"},
      {"id": "P2", "type": "page", "url": "https://example.com/a", "title": "Example",
       "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/P2"},
      {"id": "P3", "type": "page", "url": "https://example.com/b", "title": "B",
       "webSocketDebuggerUrl": "ws://evil.example:9222/devtools/page/P3"},
      {"id": "P4", "type": "page", "url": "https://example.com/c", "title": "C"}
    ]
    """#

    func testTargetMatchingPicksTheMatchingPageOnLoopback() throws {
        let targets = try CDPTarget.decodeList(Data(targetsJSON.utf8))
        XCTAssertEqual(targets.count, 5)

        let titled = CDPTargetMatcher.select(
            targets, pageURL: "https://EXAMPLE.com/a#x", title: "Example", port: 9222
        )
        XCTAssertEqual(titled?.target.id, "P2")
        XCTAssertEqual(titled?.socketURL.absoluteString, "ws://127.0.0.1:9222/devtools/page/P2")

        let untitled = CDPTargetMatcher.select(
            targets, pageURL: "https://example.com/a", title: nil, port: 9222
        )
        XCTAssertEqual(untitled?.target.type, "page")

        XCTAssertNil(CDPTargetMatcher.select(
            targets, pageURL: "https://example.com/a", title: nil, port: 9333
        ), "socket on another port")
        XCTAssertNil(CDPTargetMatcher.select(
            targets, pageURL: "https://example.com/b", title: nil, port: 9222
        ), "non-loopback socket")
        XCTAssertNil(CDPTargetMatcher.select(
            targets, pageURL: "https://example.com/c", title: nil, port: 9222
        ), "no socket")
        XCTAssertNil(CDPTargetMatcher.select(
            targets, pageURL: "https://example.com/a?q=1", title: nil, port: 9222
        ), "no exact match, no guess")
    }

    func testSocketURLValidation() {
        XCTAssertNotNil(CDPTargetMatcher.loopbackSocketURL("ws://localhost:9222/devtools/page/A", port: 9222))
        XCTAssertNil(CDPTargetMatcher.loopbackSocketURL("wss://127.0.0.1:9222/devtools/page/A", port: 9222))
        XCTAssertNil(CDPTargetMatcher.loopbackSocketURL("ws://127.0.0.1:9222/devtools/browser/A", port: 9222))
        XCTAssertNil(CDPTargetMatcher.loopbackSocketURL("ws://10.0.0.2:9222/devtools/page/A", port: 9222))
    }

    func testReaderOnlySendsRuntimeEvaluate() throws {
        XCTAssertEqual(CDPPageText.methods, ["Runtime.evaluate"])
        let data = try CDPPageText.evaluateMessageData(id: 7, maxCharacters: 1234)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(message["id"] as? Int, 7)
        let method = try XCTUnwrap(message["method"] as? String)
        XCTAssertTrue(CDPPageText.methods.contains(method))
        for prefix in ["Emulation.", "Page.", "Input.", "Target.", "DOM.", "Network."] {
            XCTAssertFalse(CDPPageText.methods.contains { $0.hasPrefix(prefix) }, prefix)
        }
        let params = try XCTUnwrap(message["params"] as? [String: Any])
        XCTAssertEqual(params["returnByValue"] as? Bool, true)
        XCTAssertEqual(params["userGesture"] as? Bool, false)
        XCTAssertEqual(params["awaitPromise"] as? Bool, false)
        let expression = try XCTUnwrap(params["expression"] as? String)
        XCTAssertTrue(expression.contains("innerText"))
        XCTAssertTrue(expression.contains("const max = 1234"))
        for forbidden in ["focus(", "click(", "location.href =", "location.assign", "dispatchEvent",
                          "scroll", "navigator.", "fetch(", "document.write", ".value ="]
        {
            XCTAssertFalse(expression.contains(forbidden), forbidden)
        }
    }

    func testReplyParsing() {
        let success = #"""
        {"id": 1, "result": {"result": {"type": "object", "value": {
          "url": "https://example.com/a", "title": "Example", "element": "article",
          "length": 20000, "text": "  Heading  \n\n\n\n Body line \n"}}}}
        """#
        let parsed = CDPPageText.parseReply(Data(success.utf8), id: 1, maxCharacters: 100)
        XCTAssertEqual(parsed, .success(PageTextResult(
            url: "https://example.com/a",
            title: "Example",
            element: "article",
            length: 20000,
            text: "Heading\n\nBody line"
        )))

        let truncated = CDPPageText.parseReply(Data(success.utf8), id: 1, maxCharacters: 4)
        XCTAssertEqual(try? truncated?.get().text, "Head")

        XCTAssertNil(CDPPageText.parseReply(
            Data(#"{"method": "Runtime.consoleAPICalled", "params": {}}"#.utf8), id: 1, maxCharacters: 10
        ), "events are skipped")
        XCTAssertNil(CDPPageText.parseReply(Data(#"{"id": 2, "result": {}}"#.utf8), id: 1, maxCharacters: 10))
        XCTAssertEqual(
            CDPPageText.parseReply(
                Data(#"{"id": 1, "error": {"code": -32000, "message": "nope"}}"#.utf8), id: 1, maxCharacters: 10
            ),
            .failure(.protocolError("nope"))
        )
        XCTAssertEqual(
            CDPPageText.parseReply(
                Data(#"{"id": 1, "result": {"result": {}, "exceptionDetails": {"text": "Uncaught"}}}"#.utf8),
                id: 1,
                maxCharacters: 10
            ),
            .failure(.exception("Uncaught"))
        )
        XCTAssertEqual(
            CDPPageText.parseReply(Data("not json".utf8), id: 1, maxCharacters: 10),
            .failure(.malformed)
        )
    }

    func testDwellWaitsThenDedupesByURL() {
        var tracker = PageTextDwellTracker(dwellSeconds: 5, recaptureSeconds: 1800)
        let start = Date(timeIntervalSince1970: 10_000)
        let page = PageTextDwellTracker.Candidate(
            bundleIdentifier: "x.browser", windowKey: "w1", urlKey: "https://example.com/a"
        )

        XCTAssertEqual(tracker.observe(page, now: start), start.addingTimeInterval(5))
        XCTAssertNil(tracker.observe(page, now: start.addingTimeInterval(1)), "unchanged page")
        XCTAssertNil(tracker.due(now: start.addingTimeInterval(4)))
        XCTAssertEqual(tracker.due(now: start.addingTimeInterval(5)), page)

        tracker.recordAttempt(page.urlKey, now: start.addingTimeInterval(5))
        XCTAssertNil(tracker.due(now: start.addingTimeInterval(6)), "read once")

        let sameURLOtherWindow = PageTextDwellTracker.Candidate(
            bundleIdentifier: "x.browser", windowKey: "w2", urlKey: page.urlKey
        )
        XCTAssertNil(tracker.observe(sameURLOtherWindow, now: start.addingTimeInterval(10)))

        let later = start.addingTimeInterval(5 + 1800)
        XCTAssertNil(tracker.observe(nil, now: later))
        XCTAssertNil(tracker.current)
        XCTAssertEqual(tracker.observe(page, now: later), later.addingTimeInterval(5), "recapture allowed")
    }

    func testNavigatingRestartsTheDwell() {
        var tracker = PageTextDwellTracker(dwellSeconds: 5, recaptureSeconds: 60)
        let start = Date(timeIntervalSince1970: 10_000)
        let a = PageTextDwellTracker.Candidate(bundleIdentifier: "x", windowKey: "w", urlKey: "https://a.com/")
        let b = PageTextDwellTracker.Candidate(bundleIdentifier: "x", windowKey: "w", urlKey: "https://b.com/")
        _ = tracker.observe(a, now: start)
        XCTAssertEqual(tracker.observe(b, now: start.addingTimeInterval(4)), start.addingTimeInterval(9))
        XCTAssertNil(tracker.due(now: start.addingTimeInterval(6)))
        XCTAssertEqual(tracker.due(now: start.addingTimeInterval(9)), b)
    }

    func testEligibilityRefusesWhatThePolicySuppresses() {
        let settings = PageTextSettings(source: .cdp, bundleIdentifiers: ["x.browser"])
        func refusal(
            settings: PageTextSettings = settings,
            captureText: Bool = true,
            bundle: String = "x.browser",
            url: String? = "https://example.com/",
            suppression: String? = nil,
            secure: Bool = false,
            secureEvent: Bool = false
        ) -> String? {
            PageTextEligibility.refusal(
                settings: settings,
                captureText: captureText,
                bundleIdentifier: bundle,
                url: url,
                suppressionReason: suppression,
                secureInput: secure,
                secureEventInput: secureEvent
            )
        }
        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(settings: PageTextSettings()), "not_enabled")
        XCTAssertEqual(refusal(bundle: "y.browser"), "not_enabled")
        XCTAssertEqual(refusal(captureText: false), "capture_text_off")
        XCTAssertEqual(refusal(url: "chrome://settings"), "not_web_page")
        XCTAssertEqual(refusal(suppression: "private_browsing"), "private_browsing")
        XCTAssertEqual(refusal(secure: true), "secure_input")
        XCTAssertEqual(refusal(secureEvent: true), "secure_input")

        var policy = ObservationPolicy()
        policy.observation.blocklist = [.init(scope: .url, urlDomain: "bank.example")]
        let reason = policy.shouldSuppress(
            bundleIdentifier: "x.browser",
            windowTitle: "Accounts",
            urlDomain: ObservationPolicy.normalizedDomain("https://www.bank.example/login"),
            role: nil,
            subrole: nil
        )
        XCTAssertEqual(refusal(url: "https://www.bank.example/login", suppression: reason), "url_policy")
    }

    func testPageContentIsAnOpenExtensionCarryingTextInAX() throws {
        let kind = HistoryEventKind.webPageContent
        XCTAssertEqual(kind.rawValue, "web.page_content")
        XCTAssertFalse(kind.isBoundary)
        XCTAssertFalse(kind.carriesAXTree, "never triggers an accessibility tree capture")

        let event = HistoryEvent(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: kind,
            window: EventStreamWindow(title: "Example", url: "https://example.com/", windowID: nil),
            ax: EventStreamAXTree(mode: .fullTree, text: "Body"),
            diagnostic: EventStreamDiagnostic(message: "cdp main 4/4")
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(json["kind"] as? String, "web.page_content")
        XCTAssertEqual((json["ax"] as? [String: Any])?["mode"] as? String, "fullTree")
        XCTAssertEqual((json["ax"] as? [String: Any])?["text"] as? String, "Body")
    }
}
