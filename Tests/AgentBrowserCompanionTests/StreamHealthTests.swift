import XCTest
@testable import AgentBrowserCompanion

@MainActor
final class StreamHealthTests: XCTestCase {
    func testCrossOriginHistoryStillEnablesBackNavigation() {
        let capabilities = AgentBrowserNavigationCapabilities.reported(
            canGoBack: false,
            canGoForward: false,
            historyLength: 3
        )

        XCTAssertTrue(capabilities.canGoBack)
        XCTAssertFalse(capabilities.canGoForward)
    }

    func testAuthoritativeRuntimeStatusCanInvalidateAStaleWebSocketStatus() {
        let source = AgentBrowserSource.local(sessionName: "stale", streamPort: 51_004)
        let session = BrowserSession(
            endpoint: "ws://127.0.0.1:51004",
            agentBrowserSource: source
        )
        let stream = AgentBrowserStream(session: session)

        stream.applyRuntimeStatus(AgentBrowserRuntimeStatus(
            browserConnected: false,
            streamingEnabled: true,
            screencasting: false,
            port: 51_004
        ))

        XCTAssertTrue(stream.hasReceivedStatus)
        XCTAssertFalse(stream.streamStatus.browserConnected)
        XCTAssertFalse(stream.streamStatus.screencasting)
        XCTAssertTrue(stream.supportsClientStreamConfiguration)
    }
}
