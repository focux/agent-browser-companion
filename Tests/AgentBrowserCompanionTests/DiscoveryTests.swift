import XCTest
@testable import AgentBrowserCompanion

final class DiscoveryTests: XCTestCase {
    func testSSHSourceUsesRemoteHostAndPortForSidebarMetadata() {
        let source = AgentBrowserSource.ssh(
            host: "developer@browser-host",
            sessionName: "checkout",
            streamPort: 43_929
        )
        let session = BrowserSession(
            endpoint: "ws://127.0.0.1:55_129",
            agentBrowserSource: source
        )

        XCTAssertEqual(session.hostname, "browser-host")
        XCTAssertEqual(session.hostLabel, "browser-host:43929")
        XCTAssertEqual(session.portLabel, "43929")
    }

    func testSSHHostValidationAcceptsAliasesAndUserQualifiedHosts() {
        XCTAssertTrue(AgentBrowserDiscoveryService.isValidSSHHost("browser-host"))
        XCTAssertTrue(AgentBrowserDiscoveryService.isValidSSHHost("developer@browser.example.com"))
        XCTAssertFalse(AgentBrowserDiscoveryService.isValidSSHHost("-oProxyCommand=bad"))
        XCTAssertFalse(AgentBrowserDiscoveryService.isValidSSHHost("host; command"))
    }

    func testKnownDiscoveryTargetsIncludeLocalAndUniqueSavedSSHHosts() {
        let sessions = [
            BrowserSession(
                endpoint: "ws://127.0.0.1:51004",
                agentBrowserSource: .local(sessionName: "local", streamPort: 51_004)
            ),
            BrowserSession(
                endpoint: "ws://127.0.0.1:51005",
                agentBrowserSource: .ssh(
                    host: "developer@browser.example.com",
                    sessionName: "remote-one",
                    streamPort: 51_005
                )
            ),
            BrowserSession(
                endpoint: "ws://127.0.0.1:51006",
                agentBrowserSource: .ssh(
                    host: "developer@browser.example.com",
                    sessionName: "remote-two",
                    streamPort: 51_006
                )
            ),
            BrowserSession(
                endpoint: "ws://127.0.0.1:51007",
                agentBrowserSource: .ssh(
                    host: "build-server",
                    sessionName: "remote-three",
                    streamPort: 51_007
                )
            )
        ]

        XCTAssertEqual(
            DiscoveryTargetCatalog.knownTargets(from: sessions),
            [.local, .ssh("developer@browser.example.com"), .ssh("build-server")]
        )
        XCTAssertEqual(AgentBrowserDiscoveryTarget.ssh("developer@browser.example.com").displayHost, "browser.example.com")
    }

    func testExistingPersistedSessionDecodesWithoutDiscoveryMetadata() throws {
        let json = """
        {
          "id": "D07E76E7-D4CB-42EB-A65F-87628D819B6A",
          "name": "Existing Session",
          "endpoint": "ws://127.0.0.1:51004?pacing=ack",
          "automaticallyConnects": true,
          "createdAt": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(BrowserSession.self, from: Data(json.utf8))

        XCTAssertNil(session.agentBrowserSource)
        XCTAssertNil(session.minimumViewport)
        XCTAssertEqual(session.hostname, "127.0.0.1")
    }

    func testSessionPersistsItsOriginalViewportBaseline() throws {
        let session = BrowserSession(
            endpoint: "ws://127.0.0.1:51004?pacing=ack",
            minimumViewport: BrowserViewportSize(width: 1_280, height: 720)
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: data)

        XCTAssertEqual(decoded.minimumViewport, BrowserViewportSize(width: 1_280, height: 720))
    }

    func testReconcilesLegacyLoopbackEndpointByDiscoveredStreamPort() {
        let legacy = BrowserSession(
            endpoint: "ws://127.0.0.1:51004?pacing=ack"
        )
        let source = AgentBrowserSource.local(sessionName: "default", streamPort: 51_004)
        let discovered = DiscoveredAgentBrowserSession(
            source: source,
            browserConnected: true,
            streamingEnabled: true,
            screencasting: true
        )

        let reconciled = LegacySessionReconciler.reconcile([legacy], with: [discovered])

        XCTAssertEqual(reconciled.first?.agentBrowserSource, source)
        XCTAssertEqual(reconciled.first?.displayTitle, "default")
        XCTAssertEqual(reconciled.first?.hostname, "localhost")
    }

    func testDoesNotReconcileUnmatchedRawEndpoint() {
        let raw = BrowserSession(
            endpoint: "wss://browser.example.com:9223"
        )
        let discovered = DiscoveredAgentBrowserSession(
            source: .local(sessionName: "default", streamPort: 9_223),
            browserConnected: true,
            streamingEnabled: true,
            screencasting: true
        )

        let reconciled = LegacySessionReconciler.reconcile([raw], with: [discovered])

        XCTAssertNil(reconciled.first?.agentBrowserSource)
    }

    func testDiscoveredSessionUsesPageTitleThenURLThenSessionName() {
        let source = AgentBrowserSource.local(sessionName: "default", streamPort: 51_004)
        let titled = DiscoveredAgentBrowserSession(
            source: source,
            browserConnected: true,
            streamingEnabled: true,
            screencasting: true,
            activePageTitle: "Chatter - BenchApp",
            activePageURL: URL(string: "http://localhost:8081/chatter")
        )
        let untitled = DiscoveredAgentBrowserSession(
            source: source,
            browserConnected: true,
            streamingEnabled: true,
            screencasting: true,
            activePageURL: URL(string: "about:blank")
        )
        let unidentified = DiscoveredAgentBrowserSession(
            source: source,
            browserConnected: true,
            streamingEnabled: true,
            screencasting: true
        )

        XCTAssertEqual(titled.displayTitle, "Chatter - BenchApp")
        XCTAssertEqual(titled.detailLabel, "default · localhost:51004")
        XCTAssertEqual(untitled.displayTitle, "about:blank")
        XCTAssertEqual(unidentified.displayTitle, "default")
    }
}
