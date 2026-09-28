import XCTest
@testable import HistoryCore

final class MediaPlaybackTests: XCTestCase {
    func testTransitionsReportStartedAndStoppedOwners() {
        let dia = MediaPlaybackOwner(
            bundleIdentifier: "company.thebrowser.dia",
            name: "Dia",
            assertionName: "Video Wake Lock"
        )
        let iina = MediaPlaybackOwner(
            bundleIdentifier: "com.colliderli.iina",
            name: "IINA",
            assertionName: nil
        )
        let changes = MediaPlayback.transitions(
            previous: [dia.bundleIdentifier: dia],
            current: [iina.bundleIdentifier: iina]
        )
        XCTAssertEqual(changes.started, [iina])
        XCTAssertEqual(changes.stopped, [dia])

        let unchanged = MediaPlayback.transitions(
            previous: [dia.bundleIdentifier: dia],
            current: [dia.bundleIdentifier: dia]
        )
        XCTAssertTrue(unchanged.started.isEmpty)
        XCTAssertTrue(unchanged.stopped.isEmpty)
    }

    func testHelperProcessesResolveToOutermostApplication() {
        XCTAssertEqual(
            MediaPlayback.owningApplicationPath(
                forExecutable: "/Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper"
            ),
            "/Applications/Dia.app"
        )
        XCTAssertNil(MediaPlayback.owningApplicationPath(forExecutable: "/usr/sbin/coreaudiod"))
    }

    func testMediaKindsAreOpenExtensions() {
        XCTAssertEqual(HistoryEventKind.mediaPlaybackStarted.rawValue, "media.playback_started")
        XCTAssertEqual(HistoryEventKind.mediaPlaybackStopped.rawValue, "media.playback_stopped")
        XCTAssertFalse(HistoryEventKind.mediaPlaybackStarted.isBoundary)
    }

    func testOnlyAttributeFreeContainersArePruned() {
        XCTAssertTrue(ObservationPolicy.isStructuralContainer(role: "AXUnknown"))
        XCTAssertTrue(ObservationPolicy.isStructuralContainer(role: "AXGroup"))
        XCTAssertFalse(ObservationPolicy.isStructuralContainer(role: "AXButton"))
        XCTAssertFalse(ObservationPolicy.isStructuralContainer(role: "AXStaticText"))
        XCTAssertFalse(ObservationPolicy.isStructuralContainer(role: "AXWebArea"))
    }
}
