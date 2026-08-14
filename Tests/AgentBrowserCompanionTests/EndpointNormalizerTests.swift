import XCTest
@testable import AgentBrowserCompanion

final class EndpointNormalizerTests: XCTestCase {
    func testAddsWebSocketSchemeAndAckPacing() {
        XCTAssertEqual(
            EndpointNormalizer.normalize("browser.example.ts.net:9223"),
            "ws://browser.example.ts.net:9223?pacing=ack"
        )
    }

    func testPreservesExistingQuery() {
        XCTAssertEqual(
            EndpointNormalizer.normalize("wss://browser.example.ts.net/stream?token=abc"),
            "wss://browser.example.ts.net/stream?token=abc&pacing=ack"
        )
    }

    func testAcceptsHTTPAndConvertsIt() {
        XCTAssertEqual(
            EndpointNormalizer.normalize("https://browser.example.ts.net"),
            "wss://browser.example.ts.net?pacing=ack"
        )
    }

    func testSessionWithoutPageMetadataFallsBackToEndpoint() {
        let session = BrowserSession(endpoint: "wss://production-browser.example.ts.net")
        XCTAssertEqual(session.displayTitle, "Production-Browser")
    }

    func testSessionUsesPageTitleThenPageURL() {
        let titled = BrowserSession(
            endpoint: "ws://127.0.0.1:9223",
            activePageTitle: "Checkout",
            activePageURL: URL(string: "https://shop.example.com/checkout")
        )
        let untitled = BrowserSession(
            endpoint: "ws://127.0.0.1:9223",
            activePageURL: URL(string: "https://shop.example.com/checkout")
        )

        XCTAssertEqual(titled.displayTitle, "Checkout")
        XCTAssertEqual(untitled.displayTitle, "https://shop.example.com/checkout")
    }

    func testExplicitPortCanBeShownWithoutRepeatingHostname() {
        let session = BrowserSession(endpoint: "wss://browser.example.ts.net:9223")
        XCTAssertEqual(session.portLabel, "9223")
    }

    func testImplicitPortDoesNotAddSidebarMetadata() {
        let session = BrowserSession(endpoint: "wss://browser.example.ts.net")
        XCTAssertNil(session.portLabel)
    }
}
