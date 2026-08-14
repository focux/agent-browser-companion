import XCTest
@testable import AgentBrowserCompanion

final class BrowserViewportSizingTests: XCTestCase {
    func testKeepsMinimumWidthAndGrowsHeightForATallCenterPane() {
        let viewport = BrowserViewportSizing.viewport(
            for: CGSize(width: 813, height: 654),
            minimumWidth: 1_280,
            minimumHeight: 720
        )

        XCTAssertEqual(viewport, BrowserViewportSize(width: 1_280, height: 1_029))
    }

    func testKeepsMinimumHeightAndGrowsWidthForAWideCenterPane() {
        let viewport = BrowserViewportSizing.viewport(
            for: CGSize(width: 1_400, height: 600),
            minimumWidth: 1_280,
            minimumHeight: 720
        )

        XCTAssertEqual(viewport, BrowserViewportSize(width: 1_680, height: 720))
    }

    func testCapsExcessivelyTallViewports() {
        let viewport = BrowserViewportSizing.viewport(
            for: CGSize(width: 500, height: 1_000),
            minimumWidth: 1_280,
            minimumHeight: 720
        )

        XCTAssertEqual(viewport, BrowserViewportSize(width: 1_280, height: 1_600))
    }

    func testCapsExcessivelyWideViewports() {
        let viewport = BrowserViewportSizing.viewport(
            for: CGSize(width: 2_000, height: 400),
            minimumWidth: 1_280,
            minimumHeight: 720
        )

        XCTAssertEqual(viewport, BrowserViewportSize(width: 2_560, height: 720))
    }
}
