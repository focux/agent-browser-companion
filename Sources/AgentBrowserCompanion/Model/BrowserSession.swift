import CoreGraphics
import Foundation

struct BrowserSession: Identifiable, Codable, Hashable {
    var id: UUID
    var endpoint: String
    var automaticallyConnects: Bool
    var createdAt: Date
    var agentBrowserSource: AgentBrowserSource?
    var activePageTitle: String?
    var activePageURL: URL?
    var minimumViewport: BrowserViewportSize?

    init(
        id: UUID = UUID(),
        endpoint: String,
        automaticallyConnects: Bool = true,
        createdAt: Date = .now,
        agentBrowserSource: AgentBrowserSource? = nil,
        activePageTitle: String? = nil,
        activePageURL: URL? = nil,
        minimumViewport: BrowserViewportSize? = nil
    ) {
        self.id = id
        self.endpoint = endpoint
        self.automaticallyConnects = automaticallyConnects
        self.createdAt = createdAt
        self.agentBrowserSource = agentBrowserSource
        self.activePageTitle = activePageTitle
        self.activePageURL = activePageURL
        self.minimumViewport = minimumViewport
    }

    var hostLabel: String {
        if let source = agentBrowserSource {
            return "\(source.displayHost):\(source.streamPort)"
        }
        guard let url = URL(string: endpoint), let host = url.host else { return endpoint }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    var hostname: String {
        if let source = agentBrowserSource { return source.displayHost }
        return URL(string: endpoint)?.host ?? "Other"
    }

    var portLabel: String? {
        if let source = agentBrowserSource { return String(source.streamPort) }
        return URL(string: endpoint)?.port.map(String.init)
    }

    var displayTitle: String {
        BrowserTitleResolver.resolve(
            pageTitle: activePageTitle,
            pageURL: activePageURL,
            fallback: agentBrowserSource?.sessionName ?? EndpointNormalizer.displayName(for: endpoint)
        )
    }

    var unmanagedLoopbackStreamPort: Int? {
        guard agentBrowserSource == nil,
              let url = URL(string: endpoint),
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        return url.port
    }
}

enum BrowserTitleResolver {
    static func resolve(pageTitle: String?, pageURL: URL?, fallback: String) -> String {
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        if let pageURL { return pageURL.absoluteString }
        return fallback
    }
}

enum LegacySessionReconciler {
    static func reconcile(
        _ sessions: [BrowserSession],
        with discovered: [DiscoveredAgentBrowserSession]
    ) -> [BrowserSession] {
        let localSourcesByPort = Dictionary(grouping: discovered.map(\.source).filter {
            $0.location == .local
        }, by: \.streamPort)
        var claimedIdentities = Set(sessions.compactMap { $0.agentBrowserSource?.identity })
        var result = sessions

        for index in result.indices {
            guard let port = result[index].unmanagedLoopbackStreamPort,
                  let matches = localSourcesByPort[port],
                  matches.count == 1,
                  let source = matches.first,
                  !claimedIdentities.contains(source.identity) else { continue }
            result[index].agentBrowserSource = source
            claimedIdentities.insert(source.identity)
        }
        return result
    }
}

struct AgentBrowserSource: Codable, Hashable {
    enum Location: String, Codable {
        case local
        case ssh
    }

    var location: Location
    var sessionName: String
    var sshHost: String?
    var streamPort: Int

    static func local(sessionName: String, streamPort: Int) -> Self {
        Self(location: .local, sessionName: sessionName, streamPort: streamPort)
    }

    static func ssh(host: String, sessionName: String, streamPort: Int) -> Self {
        Self(location: .ssh, sessionName: sessionName, sshHost: host, streamPort: streamPort)
    }

    var displayHost: String {
        switch location {
        case .local:
            "localhost"
        case .ssh:
            sshHost?
                .split(separator: "@", maxSplits: 1)
                .last
                .map(String.init) ?? "Remote"
        }
    }

    var identity: String {
        "\(location.rawValue)|\(sshHost ?? "")|\(sessionName)"
    }
}

enum AgentBrowserNavigationCommand: String, CaseIterable {
    case back
    case forward
    case reload

    var label: String { rawValue.capitalized }
}

struct BrowserViewportSize: Codable, Equatable, Hashable {
    let width: Int
    let height: Int
}

struct StreamClientConfiguration: Equatable {
    let maxFPS: Int
    let pacing: StreamPacing
    let pausesFrameDelivery: Bool
}

enum StreamActivityPolicy {
    static let backgroundFPS = 1
    static let sidebarPreviewFPS = 12

    static func configuration(
        preferredFPS: Int,
        preferredPacing: StreamPacing,
        isForeground: Bool,
        isPreviewing: Bool
    ) -> StreamClientConfiguration {
        let preferredFPS = min(max(preferredFPS, 0), 120)
        if isForeground {
            return StreamClientConfiguration(
                maxFPS: preferredFPS,
                pacing: preferredPacing,
                pausesFrameDelivery: false
            )
        }

        if isPreviewing {
            return StreamClientConfiguration(
                maxFPS: cappedRate(preferredFPS, at: sidebarPreviewFPS),
                pacing: .acknowledgement,
                pausesFrameDelivery: false
            )
        }

        return StreamClientConfiguration(
            maxFPS: cappedRate(preferredFPS, at: backgroundFPS),
            pacing: .acknowledgement,
            pausesFrameDelivery: true
        )
    }

    private static func cappedRate(_ preferredFPS: Int, at ceiling: Int) -> Int {
        preferredFPS == 0 ? ceiling : min(preferredFPS, ceiling)
    }
}

struct AgentBrowserNavigationCapabilities: Equatable {
    var canGoBack = false
    var canGoForward = false

    static func reported(
        canGoBack: Bool,
        canGoForward: Bool,
        historyLength: Int
    ) -> Self {
        Self(
            canGoBack: canGoBack || historyLength > 1,
            canGoForward: canGoForward
        )
    }
}

enum StreamConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .connected: "Live"
        case .failed: "Connection failed"
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

struct StreamMetadata: Equatable {
    var deviceWidth: Int = 0
    var deviceHeight: Int = 0
    var pageScaleFactor: Double = 1
    var offsetTop: Double = 0
    var scrollOffsetX: Double = 0
    var scrollOffsetY: Double = 0
    var timestamp: Double = 0
}

struct BrowserFrame {
    let sequence: Int
    let image: CGImage
    let metadata: StreamMetadata
}

struct StreamStatus: Equatable {
    var browserConnected = false
    var screencasting = false
    var viewportWidth = 0
    var viewportHeight = 0
}

enum StreamPacing: String, CaseIterable, Identifiable {
    case acknowledgement = "ack"
    case push

    var id: String { rawValue }
    var label: String { self == .acknowledgement ? "Freshest frame" : "Maximum throughput" }
}
