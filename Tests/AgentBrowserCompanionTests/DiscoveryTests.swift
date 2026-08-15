import XCTest
@testable import AgentBrowserCompanion

final class DiscoveryTests: XCTestCase {
    func testKnownDiscoveryTargetsAlwaysIncludesLocal() {
        XCTAssertEqual(DiscoveryTargetCatalog.knownTargets(sshHosts: []), [.local])
    }

    func testLocalCommandEnvironmentFindsAgentBrowserInstalledByNVM() throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nvmBinDirectory = homeDirectory
            .appendingPathComponent(".nvm/versions/node/v22.16.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nvmBinDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let agentBrowser = nvmBinDirectory.appendingPathComponent("agent-browser")
        XCTAssertTrue(FileManager.default.createFile(atPath: agentBrowser.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: agentBrowser.path
        )

        let environment = AgentBrowserCommandEnvironment.local(
            base: ["PATH": "/usr/bin:/bin"],
            homeDirectory: homeDirectory
        )

        let firstSearchDirectory = try XCTUnwrap(
            environment["PATH"]?.split(separator: ":").first.map(String.init)
        )
        XCTAssertEqual(
            URL(fileURLWithPath: firstSearchDirectory).resolvingSymlinksInPath(),
            nvmBinDirectory.resolvingSymlinksInPath()
        )
    }

    func testLocalCommandEnvironmentFindsCommonUserPackageManagerInstalls() throws {
        let installationDirectories = [
            ".cargo/bin",
            ".volta/bin",
            ".bun/bin",
            ".npm-global/bin",
            ".yarn/bin",
            ".config/yarn/global/node_modules/.bin",
            "Library/pnpm",
            ".asdf/shims",
            ".local/share/mise/shims",
            ".local/share/fnm/node-versions/v22.16.0/installation/bin",
            ".nix-profile/bin",
        ]

        for relativeDirectory in installationDirectories {
            let homeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let binDirectory = homeDirectory
                .appendingPathComponent(relativeDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: binDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: homeDirectory) }

            let agentBrowser = binDirectory.appendingPathComponent("agent-browser")
            XCTAssertTrue(
                FileManager.default.createFile(atPath: agentBrowser.path, contents: Data())
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: agentBrowser.path
            )

            let environment = AgentBrowserCommandEnvironment.local(
                base: ["PATH": "/usr/bin:/bin"],
                homeDirectory: homeDirectory
            )
            let firstSearchDirectory = try XCTUnwrap(
                environment["PATH"]?.split(separator: ":").first.map(String.init)
            )
            XCTAssertEqual(
                URL(fileURLWithPath: firstSearchDirectory).resolvingSymlinksInPath(),
                binDirectory.resolvingSymlinksInPath(),
                "Failed to resolve an Agent Browser installation in \(relativeDirectory)"
            )
        }
    }

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
            DiscoveryTargetCatalog.knownTargets(
                sshHosts: DiscoveryTargetCatalog.migratedSSHHosts(from: sessions)
            ),
            [.local, .ssh("developer@browser.example.com"), .ssh("build-server")]
        )
        XCTAssertEqual(AgentBrowserDiscoveryTarget.ssh("developer@browser.example.com").displayHost, "browser.example.com")
    }

    func testSavedSSHHostsAreNormalizedAndDeduplicated() {
        XCTAssertEqual(
            DiscoveryTargetCatalog.normalizedSSHHosts([
                " build-server ",
                "BUILD-SERVER",
                "developer@browser.example.com",
                "-oProxyCommand=bad",
            ]),
            ["developer@browser.example.com", "build-server"]
        )
    }

    func testAutomaticSessionsRequireTwoMissingDiscoveryPassesBeforeRemoval() {
        let first = AutomaticSessionRetention.nextMissingPassCount(
            previous: 0,
            isPresent: false
        )
        XCTAssertFalse(AutomaticSessionRetention.shouldRemove(missingPassCount: first))

        let second = AutomaticSessionRetention.nextMissingPassCount(
            previous: first,
            isPresent: false
        )
        XCTAssertTrue(AutomaticSessionRetention.shouldRemove(missingPassCount: second))
        XCTAssertEqual(
            AutomaticSessionRetention.nextMissingPassCount(previous: second, isPresent: true),
            0
        )
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
