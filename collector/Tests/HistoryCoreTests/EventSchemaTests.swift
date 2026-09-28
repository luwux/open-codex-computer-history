import XCTest
@testable import HistoryCore

final class EventSchemaTests: XCTestCase {
    func testEventUsesRecoveredNestedSchema() throws {
        let event = HistoryEvent(
            id: 7,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .keyboardShortcut,
            app: EventStreamApp(
                name: "Editor",
                secureInput: false,
                processIdentifier: 42,
                bundleIdentifier: "com.example.Editor"
            ),
            window: EventStreamWindow(
                title: "Document",
                url: "https://example.com/doc",
                windowID: 123
            ),
            keyboard: EventStreamKeyboardInteraction(
                text: nil,
                keyEquivalent: "s",
                modifiers: ["command"],
                target: EventStreamAXElement(
                    role: "AXTextArea",
                    subrole: nil,
                    title: "Body",
                    description: nil,
                    value: nil,
                    placeholder: nil,
                    identifier: "editor"
                )
            ),
            ax: EventStreamAXTree(mode: .fullTree, text: "AXTextArea[Body]")
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(event))
                as? [String: Any]
        )

        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual(object["kind"] as? String, "keyboard.shortcut")
        XCTAssertNotNil(object["app"])
        XCTAssertNotNil(object["window"])
        XCTAssertNotNil(object["keyboard"])
        XCTAssertNotNil(object["ax"])
        XCTAssertNil(object["type"])
        XCTAssertNil(object["application"])
        XCTAssertNil(object["sessionID"])
        XCTAssertNil(object["segmentID"])
    }

    func testPresenceEventsAreBoundariesWithoutPayload() throws {
        let kinds: [HistoryEventKind: String] = [
            .systemScreenLocked: "system.screen_locked",
            .systemScreenUnlocked: "system.screen_unlocked",
            .systemWillSleep: "system.will_sleep",
            .systemDidWake: "system.did_wake",
        ]
        for (kind, rawValue) in kinds {
            XCTAssertEqual(kind.rawValue, rawValue)
            XCTAssertTrue(kind.isBoundary)

            let event = HistoryEvent(
                id: 1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                kind: kind
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoder.encode(event))
                    as? [String: Any]
            )
            XCTAssertEqual(object["kind"] as? String, rawValue)
            XCTAssertNil(object["app"])
            XCTAssertNil(object["window"])
            XCTAssertNil(object["ax"])
        }
        XCTAssertTrue(HistoryEventKind.sessionStarted.isBoundary)
        XCTAssertFalse(HistoryEventKind.windowChanged.isBoundary)
    }

    func testSettingsEncodeLikeRecoveredIPCSettings() throws {
        let settings = ObservationPolicy(
            observation: .init(
                defaultApplicationBehavior: .observe,
                defaultURLBehavior: .doNotObserve,
                allowlist: [.init(scope: .url, urlDomain: "example.com")],
                blocklist: []
            ),
            showMenuBarIcon: true,
            captureText: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
                as? [String: Any]
        )
        let observation = try XCTUnwrap(object["observation"] as? [String: Any])
        XCTAssertEqual(observation["defaultApplicationBehavior"] as? String, "observe")
        XCTAssertEqual(observation["defaultURLBehavior"] as? String, "do_not_observe")
        XCTAssertEqual(object["showMenuBarIcon"] as? Bool, true)
    }
}
