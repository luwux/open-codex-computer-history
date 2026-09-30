import CoreGraphics
import XCTest
@testable import HistoryCore

final class AXCaptureSettingsTests: XCTestCase {
    func testConfigWithoutCaptureSettingsUsesDefaults() throws {
        let policy = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"captureText": false}"#.utf8)
        )
        XCTAssertEqual(policy.axCapture, AXCaptureSettings())
        XCTAssertEqual(policy.axCapture.visibleChildrenAttributeByRole["AXTable"], "AXVisibleRows")
    }

    func testPartialCaptureSettingsKeepOtherDefaults() throws {
        let policy = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: Data(#"{"axCapture": {"minimumTreeIntervalSeconds": 0, "visibleChildrenAttributeByRole": {}}}"#.utf8)
        )
        XCTAssertEqual(policy.axCapture.minimumTreeIntervalSeconds, 0)
        XCTAssertTrue(policy.axCapture.visibleChildrenAttributeByRole.isEmpty)
        XCTAssertEqual(
            policy.axCapture.treeTimeBudgetMilliseconds,
            AXCaptureSettings().treeTimeBudgetMilliseconds
        )
    }

    func testPolicyRoundTripsCaptureSettings() throws {
        var policy = ObservationPolicy()
        policy.axCapture.maximumChildrenPerElement = 42
        let decoded = try JSONDecoder().decode(
            ObservationPolicy.self,
            from: JSONEncoder().encode(policy)
        )
        XCTAssertEqual(decoded, policy)
    }

    func testThrottleSkipsUnchangedWindowWithinInterval() {
        var throttle = AXCaptureThrottle(minimumInterval: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.shouldCapture(windowKey: "w1", context: "a", now: start))
        throttle.recordCapture(windowKey: "w1", context: "a", at: start)

        XCTAssertFalse(throttle.shouldCapture(
            windowKey: "w1", context: "a", now: start.addingTimeInterval(1)
        ))
        XCTAssertTrue(throttle.shouldCapture(
            windowKey: "w1", context: "a", now: start.addingTimeInterval(2)
        ))
    }

    func testThrottleCapturesOnContextChangeNewWindowOrForce() {
        var throttle = AXCaptureThrottle(minimumInterval: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        throttle.recordCapture(windowKey: "w1", context: "a", at: start)
        let soon = start.addingTimeInterval(0.5)

        XCTAssertTrue(throttle.shouldCapture(windowKey: "w1", context: "b", now: soon))
        XCTAssertTrue(throttle.shouldCapture(windowKey: "w2", context: "a", now: soon))
        XCTAssertTrue(throttle.shouldCapture(windowKey: "w1", context: "a", now: soon, force: true))
        XCTAssertTrue(throttle.shouldCapture(windowKey: nil, context: "a", now: soon))
    }
}

final class RecorderHotPathTests: XCTestCase {
    func testTypingSelectionAndBoundariesNeverCarryTrees() {
        for kind: HistoryEventKind in [
            .keyboardTextInput, .selectionChanged, .sessionStarted, .sessionEnded,
            .systemScreenLocked, .systemDidWake, .mediaPlaybackStarted,
        ] {
            XCTAssertFalse(kind.carriesAXTree, kind.rawValue)
        }
        for kind: HistoryEventKind in [.windowChanged, .mouseClick, .keyboardSubmit] {
            XCTAssertTrue(kind.carriesAXTree, kind.rawValue)
        }
    }

    func testEventTapExcludesHighRateEvents() {
        let mask = RecorderEventTap.mask
        for type: CGEventType in [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .flagsChanged, .scrollWheel, .keyUp,
        ] {
            XCTAssertEqual(mask & (CGEventMask(1) << type.rawValue), 0, "\(type.rawValue)")
        }
        XCTAssertNotEqual(mask & (CGEventMask(1) << CGEventType.keyDown.rawValue), 0)
    }
}
