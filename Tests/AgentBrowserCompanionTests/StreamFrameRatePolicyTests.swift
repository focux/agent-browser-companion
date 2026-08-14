import XCTest
@testable import AgentBrowserCompanion

final class StreamFrameRatePolicyTests: XCTestCase {
    func testForegroundSessionUsesThePreferredRate() {
        XCTAssertEqual(
            StreamActivityPolicy.configuration(
                preferredFPS: 30,
                preferredPacing: .push,
                isForeground: true,
                isPreviewing: false
            ),
            StreamClientConfiguration(maxFPS: 30, pacing: .push, pausesFrameDelivery: false)
        )
    }

    func testBackgroundSessionPausesAfterItsOpeningFrame() {
        XCTAssertEqual(
            StreamActivityPolicy.configuration(
                preferredFPS: 30,
                preferredPacing: .push,
                isForeground: false,
                isPreviewing: false
            ),
            StreamClientConfiguration(maxFPS: 1, pacing: .acknowledgement, pausesFrameDelivery: true)
        )
    }

    func testSidebarPreviewTemporarilyUsesAPreviewRate() {
        XCTAssertEqual(
            StreamActivityPolicy.configuration(
                preferredFPS: 30,
                preferredPacing: .push,
                isForeground: false,
                isPreviewing: true
            ),
            StreamClientConfiguration(maxFPS: 12, pacing: .acknowledgement, pausesFrameDelivery: false)
        )
    }

    func testUnlimitedForegroundDoesNotMakeBackgroundStreamsUnlimited() {
        XCTAssertEqual(
            StreamActivityPolicy.configuration(
                preferredFPS: 0,
                preferredPacing: .push,
                isForeground: false,
                isPreviewing: false
            ),
            StreamClientConfiguration(maxFPS: 1, pacing: .acknowledgement, pausesFrameDelivery: true)
        )
    }
}
