import Darwin
import Foundation

struct DiscoveredAgentBrowserSession: Identifiable, Hashable {
    let source: AgentBrowserSource
    let browserConnected: Bool
    let streamingEnabled: Bool
    let screencasting: Bool
    let activePageTitle: String?
    let activePageURL: URL?

    init(
        source: AgentBrowserSource,
        browserConnected: Bool,
        streamingEnabled: Bool,
        screencasting: Bool,
        activePageTitle: String? = nil,
        activePageURL: URL? = nil
    ) {
        self.source = source
        self.browserConnected = browserConnected
        self.streamingEnabled = streamingEnabled
        self.screencasting = screencasting
        self.activePageTitle = activePageTitle
        self.activePageURL = activePageURL
    }

    var id: String { source.identity }

    var statusLabel: String {
        if !browserConnected { return "Browser unavailable" }
        if !streamingEnabled { return "Streaming disabled" }
        return screencasting ? "Live" : "Ready"
    }

    var displayTitle: String {
        BrowserTitleResolver.resolve(
            pageTitle: activePageTitle,
            pageURL: activePageURL,
            fallback: source.sessionName
        )
    }

    var detailLabel: String {
        let endpoint = "\(source.displayHost):\(source.streamPort)"
        guard displayTitle != source.sessionName else { return endpoint }
        return "\(source.sessionName) · \(endpoint)"
    }
}

struct AgentBrowserRuntimeStatus: Equatable {
    let browserConnected: Bool
    let streamingEnabled: Bool
    let screencasting: Bool
    let port: Int?
    let activePageTitle: String?
    let activePageURL: URL?

    init(
        browserConnected: Bool,
        streamingEnabled: Bool,
        screencasting: Bool,
        port: Int?,
        activePageTitle: String? = nil,
        activePageURL: URL? = nil
    ) {
        self.browserConnected = browserConnected
        self.streamingEnabled = streamingEnabled
        self.screencasting = screencasting
        self.port = port
        self.activePageTitle = activePageTitle
        self.activePageURL = activePageURL
    }
}

struct AgentBrowserCDPContext: Equatable {
    let browserURL: URL
    let activePageURL: URL?
}

enum AgentBrowserDiscoveryTarget: Hashable {
    case local
    case ssh(String)

    var displayHost: String {
        switch self {
        case .local:
            "localhost"
        case .ssh(let host):
            host
                .split(separator: "@", maxSplits: 1)
                .last
                .map(String.init) ?? host
        }
    }
}

enum DiscoveryTargetCatalog {
    static func knownTargets(from sessions: [BrowserSession]) -> [AgentBrowserDiscoveryTarget] {
        var seenHosts = Set<String>()
        let remoteTargets = sessions.compactMap { session -> AgentBrowserDiscoveryTarget? in
            guard session.agentBrowserSource?.location == .ssh,
                  let rawHost = session.agentBrowserSource?.sshHost?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  AgentBrowserDiscoveryService.isValidSSHHost(rawHost),
                  seenHosts.insert(rawHost.lowercased()).inserted else { return nil }
            return .ssh(rawHost)
        }
        .sorted { $0.displayHost.localizedCaseInsensitiveCompare($1.displayHost) == .orderedAscending }

        return [.local] + remoteTargets
    }
}

enum AgentBrowserCommandEnvironment {
    static let current = local()

    static func local(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String: String] {
        let existingPath = base["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        if existingPath.contains(where: {
            let executable = URL(fileURLWithPath: $0)
                .appendingPathComponent("agent-browser")
            return fileManager.isExecutableFile(atPath: executable.path)
        }) {
            return base
        }

        let environmentCandidates = [
            base["NVM_BIN"],
            base["PNPM_HOME"],
            base["VOLTA_HOME"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("bin").path
            },
            base["CARGO_HOME"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("bin").path
            },
            base["BUN_INSTALL"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("bin").path
            },
        ]
        .compactMap { $0 }
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let homeCandidates = [
            "bin",
            ".local/bin",
            ".volta/bin",
            ".bun/bin",
            ".cargo/bin",
            ".npm-global/bin",
            ".yarn/bin",
            ".config/yarn/global/node_modules/.bin",
            "Library/pnpm",
            ".asdf/shims",
            ".local/share/mise/shims",
            ".local/share/fnm/aliases/default/bin",
            ".nix-profile/bin",
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }

        let nvmVersionsDirectory = homeDirectory
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvmCandidates = versionedDirectories(
            in: nvmVersionsDirectory,
            appending: "bin",
            fileManager: fileManager
        )

        let fnmVersionsDirectory = homeDirectory
            .appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true)
        let fnmCandidates = versionedDirectories(
            in: fnmVersionsDirectory,
            appending: "installation/bin",
            fileManager: fileManager
        )

        let systemCandidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/nix/var/nix/profiles/default/bin",
        ]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let candidates = environmentCandidates
            + homeCandidates
            + nvmCandidates
            + fnmCandidates
            + systemCandidates
        guard let agentBrowserDirectory = candidates.first(where: {
            fileManager.isExecutableFile(
                atPath: $0.appendingPathComponent("agent-browser").path
            )
        }) else {
            return base
        }

        var environment = base
        environment["PATH"] = ([agentBrowserDirectory.path] + existingPath)
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) { paths.append(path) }
            }
            .joined(separator: ":")
        return environment
    }

    private static func versionedDirectories(
        in directory: URL,
        appending relativePath: String,
        fileManager: FileManager
    ) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
        .sorted {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: [.caseInsensitive, .numeric]
            ) == .orderedDescending
        }
        .map { $0.appendingPathComponent(relativePath, isDirectory: true) }
    }
}

enum AgentBrowserDiscoveryError: LocalizedError {
    case invalidSSHHost
    case commandFailed(String)
    case malformedResponse
    case missingStreamPort(String)
    case tunnelFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSSHHost:
            "Enter a valid SSH host or SSH config alias."
        case .commandFailed(let message):
            message
        case .malformedResponse:
            "Agent Browser returned an unreadable response."
        case .missingStreamPort(let name):
            "Agent Browser did not report a stream port for \(name)."
        case .tunnelFailed(let message):
            "The SSH tunnel could not be opened. \(message)"
        }
    }
}

struct AgentBrowserDiscoveryService {
    static func cdpContext(for source: AgentBrowserSource) async throws -> AgentBrowserCDPContext {
        try await Task.detached(priority: .utility) {
            let commandTarget = try target(for: source)
            let cdpOutput = try runAgentBrowser(
                arguments: ["--session", source.sessionName, "get", "cdp-url", "--json"],
                target: commandTarget
            )
            let cdpResponse: Response<CDPURLResponse> = try decodeResponse(cdpOutput)
            guard cdpResponse.success,
                  let rawURL = cdpResponse.data?.cdpUrl,
                  let browserURL = URL(string: rawURL) else {
                throw AgentBrowserDiscoveryError.commandFailed(
                    cdpResponse.error ?? "Agent Browser did not provide a CDP endpoint."
                )
            }

            let tabsOutput = try runAgentBrowser(
                arguments: ["--session", source.sessionName, "tab", "list", "--json"],
                target: commandTarget
            )
            let tabsResponse: Response<TabListResponse> = try decodeResponse(tabsOutput)
            let activePageURL = tabsResponse.data?.tabs
                .first(where: { $0.active })
                .flatMap { URL(string: $0.url) }
            return AgentBrowserCDPContext(browserURL: browserURL, activePageURL: activePageURL)
        }.value
    }

    static func runtimeStatus(for source: AgentBrowserSource) async throws -> AgentBrowserRuntimeStatus {
        try await Task.detached(priority: .utility) {
            let commandTarget = try target(for: source)
            let output = try runAgentBrowser(
                arguments: ["--session", source.sessionName, "stream", "status", "--json"],
                target: commandTarget
            )
            let response: Response<StreamStatusResponse> = try decodeResponse(output)
            guard response.success, let status = response.data else {
                throw AgentBrowserDiscoveryError.commandFailed(
                    response.error ?? "Could not read the stream status for \(source.sessionName)."
                )
            }
            let tabsOutput = try? runAgentBrowser(
                arguments: ["--session", source.sessionName, "tab", "list", "--json"],
                target: commandTarget
            )
            let tabsResponse: Response<TabListResponse>? = tabsOutput.flatMap {
                try? decodeResponse($0)
            }
            let activeTab = tabsResponse?.data?.tabs.first(where: \.active)

            return AgentBrowserRuntimeStatus(
                browserConnected: status.connected,
                streamingEnabled: status.enabled,
                screencasting: status.screencasting,
                port: status.port,
                activePageTitle: activeTab?.title,
                activePageURL: activeTab.flatMap { URL(string: $0.url) }
            )
        }.value
    }

    static func discover(_ target: AgentBrowserDiscoveryTarget) async throws -> [DiscoveredAgentBrowserSession] {
        try await Task.detached(priority: .userInitiated) {
            let listOutput = try runAgentBrowser(arguments: ["session", "list", "--json"], target: target)
            let list: Response<SessionList> = try decodeResponse(listOutput)
            guard list.success, let sessionNames = list.data?.sessions else {
                throw AgentBrowserDiscoveryError.commandFailed(list.error ?? "Agent Browser session discovery failed.")
            }

            return try sessionNames.map { sessionName in
                let statusOutput = try runAgentBrowser(
                    arguments: ["--session", sessionName, "stream", "status", "--json"],
                    target: target
                )
                let response: Response<StreamStatusResponse> = try decodeResponse(statusOutput)
                guard response.success, let status = response.data else {
                    throw AgentBrowserDiscoveryError.commandFailed(
                        response.error ?? "Could not read the stream status for \(sessionName)."
                    )
                }
                guard let port = status.port else {
                    throw AgentBrowserDiscoveryError.missingStreamPort(sessionName)
                }

                let source: AgentBrowserSource
                switch target {
                case .local:
                    source = .local(sessionName: sessionName, streamPort: port)
                case .ssh(let host):
                    source = .ssh(host: host, sessionName: sessionName, streamPort: port)
                }
                let tabsOutput = try? runAgentBrowser(
                    arguments: ["--session", sessionName, "tab", "list", "--json"],
                    target: target
                )
                let tabsResponse: Response<TabListResponse>? = tabsOutput.flatMap {
                    try? decodeResponse($0)
                }
                let activeTab = tabsResponse?.data?.tabs.first(where: \.active)
                return DiscoveredAgentBrowserSession(
                    source: source,
                    browserConnected: status.connected,
                    streamingEnabled: status.enabled,
                    screencasting: status.screencasting,
                    activePageTitle: activeTab?.title,
                    activePageURL: activeTab.flatMap { URL(string: $0.url) }
                )
            }
        }.value
    }

    static func refreshedSource(_ source: AgentBrowserSource) async throws -> AgentBrowserSource {
        let status = try await runtimeStatus(for: source)
        guard let port = status.port else {
            throw AgentBrowserDiscoveryError.missingStreamPort(source.sessionName)
        }
        var refreshed = source
        refreshed.streamPort = port
        return refreshed
    }

    static func run(_ command: AgentBrowserNavigationCommand, for source: AgentBrowserSource) async throws {
        try await Task.detached(priority: .userInitiated) {
            let commandTarget = try target(for: source)
            do {
                _ = try runAgentBrowser(
                    arguments: ["--session", source.sessionName, command.rawValue],
                    target: commandTarget
                )
            } catch AgentBrowserDiscoveryError.commandFailed(let message)
                where message.localizedCaseInsensitiveContains("Inspected target navigated or closed") {
                // CDP can cancel Runtime.evaluate while a navigation command is
                // successfully replacing the document. Confirm the browser is
                // still attached before treating that cancellation as success.
                let statusOutput = try runAgentBrowser(
                    arguments: ["--session", source.sessionName, "stream", "status", "--json"],
                    target: commandTarget
                )
                let status: Response<StreamStatusResponse> = try decodeResponse(statusOutput)
                guard status.success, status.data?.connected == true else {
                    throw AgentBrowserDiscoveryError.commandFailed(message)
                }
            }
        }.value
    }

    static func setViewport(width: Int, height: Int, for source: AgentBrowserSource) async throws {
        try await Task.detached(priority: .utility) {
            let output = try runAgentBrowser(
                arguments: [
                    "--session", source.sessionName,
                    "set", "viewport", String(width), String(height),
                    "--json"
                ],
                target: try target(for: source)
            )
            let response: Response<ViewportResponse> = try decodeResponse(output)
            guard response.success,
                  response.data?.width == width,
                  response.data?.height == height else {
                throw AgentBrowserDiscoveryError.commandFailed(
                    response.error ?? "Agent Browser did not apply the requested viewport."
                )
            }
        }.value
    }

    static func navigationCapabilities(
        for source: AgentBrowserSource
    ) async throws -> AgentBrowserNavigationCapabilities {
        try await Task.detached(priority: .utility) {
            let expression = "JSON.stringify({canGoBack: globalThis.navigation?.canGoBack ?? false, "
                + "canGoForward: globalThis.navigation?.canGoForward ?? false, "
                + "historyLength: globalThis.history?.length ?? 1})"
            let output = try runAgentBrowser(
                arguments: ["--session", source.sessionName, "eval", expression, "--json"],
                target: try target(for: source)
            )
            let response: Response<EvaluationResponse> = try decodeResponse(output)
            guard response.success,
                  let result = response.data?.result,
                  let data = result.data(using: .utf8),
                  let state = try? JSONDecoder().decode(NavigationState.self, from: data) else {
                throw AgentBrowserDiscoveryError.commandFailed(
                    response.error ?? "The browser history state could not be read."
                )
            }
            return AgentBrowserNavigationCapabilities.reported(
                canGoBack: state.canGoBack,
                canGoForward: state.canGoForward,
                historyLength: state.historyLength
            )
        }.value
    }

    static func isValidSSHHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        return trimmed.range(of: #"^[A-Za-z0-9_.:@-]+$"#, options: .regularExpression) != nil
    }

    private static func target(for source: AgentBrowserSource) throws -> AgentBrowserDiscoveryTarget {
        switch source.location {
        case .local:
            return .local
        case .ssh:
            guard let host = source.sshHost, isValidSSHHost(host) else {
                throw AgentBrowserDiscoveryError.invalidSSHHost
            }
            return .ssh(host)
        }
    }

    private static func runAgentBrowser(
        arguments: [String],
        target: AgentBrowserDiscoveryTarget
    ) throws -> String {
        let quotedArguments = arguments.map(shellQuote).joined(separator: " ")
        let command = "if command -v agent-browser >/dev/null 2>&1 && command -v node >/dev/null 2>&1; "
            + "then agent-browser \(quotedArguments); "
            + "elif command -v agent-browser >/dev/null 2>&1 && command -v bunx >/dev/null 2>&1; "
            + "then bunx --bun agent-browser \(quotedArguments); "
            + "elif command -v agent-browser >/dev/null 2>&1; then agent-browser \(quotedArguments); "
            + "else printf 'agent-browser is not installed\\n' >&2; exit 127; fi"
        switch target {
        case .local:
            return try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command],
                environment: AgentBrowserCommandEnvironment.current
            )
        case .ssh(let rawHost):
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidSSHHost(host) else { throw AgentBrowserDiscoveryError.invalidSSHHost }
            // A number of lightweight remote servers have Bun but no Node.
            // Bun can run Agent Browser directly even when its installed wrapper
            // has a `node` shebang, so select the available runtime explicitly.
            let remoteCommand = "exec \"${SHELL:-/bin/sh}\" -lc \(shellQuote(command))"
            return try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    "--", host, remoteCommand
                ]
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func decodeResponse<Value: Decodable>(_ output: String) throws -> Response<Value> {
        let jsonLine = output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let jsonLine,
              let data = String(jsonLine).data(using: .utf8),
              let response = try? JSONDecoder().decode(Response<Value>.self, from: data) else {
            throw AgentBrowserDiscoveryError.malformedResponse
        }
        return response
    }

    private struct Response<Value: Decodable>: Decodable {
        let success: Bool
        let data: Value?
        let error: String?
    }

    private struct SessionList: Decodable {
        let sessions: [String]
    }

    private struct StreamStatusResponse: Decodable {
        let connected: Bool
        let enabled: Bool
        let port: Int?
        let screencasting: Bool
    }

    private struct EvaluationResponse: Decodable {
        let result: String
    }

    private struct ViewportResponse: Decodable {
        let width: Int
        let height: Int
    }

    private struct CDPURLResponse: Decodable {
        let cdpUrl: String
    }

    private struct TabListResponse: Decodable {
        let tabs: [TabResponse]
    }

    private struct TabResponse: Decodable {
        let active: Bool
        let title: String?
        let url: String
    }

    private struct NavigationState: Decodable {
        let canGoBack: Bool
        let canGoForward: Bool
        let historyLength: Int
    }
}

final class SSHTunnelManager {
    private struct Tunnel {
        let process: Process
        let standardError: Pipe
        let host: String
        let remotePort: Int
        let localPort: Int
    }

    private var streamTunnels: [BrowserSession.ID: Tunnel] = [:]
    private var cdpTunnels: [BrowserSession.ID: Tunnel] = [:]

    func open(for sessionID: BrowserSession.ID, host: String, remotePort: Int) async throws -> String {
        guard AgentBrowserDiscoveryService.isValidSSHHost(host), (1...65_535).contains(remotePort) else {
            throw AgentBrowserDiscoveryError.invalidSSHHost
        }
        stopStream(for: sessionID)

        let tunnel = try await Self.makeTunnel(host: host, remotePort: remotePort)
        streamTunnels[sessionID] = tunnel
        return "ws://127.0.0.1:\(tunnel.localPort)"
    }

    func cdpBrowserURL(
        for sessionID: BrowserSession.ID,
        host: String,
        remoteURL: URL
    ) async throws -> URL {
        guard AgentBrowserDiscoveryService.isValidSSHHost(host),
              let remotePort = remoteURL.port,
              (1...65_535).contains(remotePort) else {
            throw AgentBrowserDiscoveryError.invalidSSHHost
        }

        let tunnel: Tunnel
        if let existing = cdpTunnels[sessionID],
           existing.process.isRunning,
           existing.host == host,
           existing.remotePort == remotePort {
            tunnel = existing
        } else {
            stopCDP(for: sessionID)
            tunnel = try await Self.makeTunnel(host: host, remotePort: remotePort)
            cdpTunnels[sessionID] = tunnel
        }

        guard var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) else {
            throw AgentBrowserDiscoveryError.tunnelFailed("The CDP endpoint was invalid.")
        }
        components.host = "127.0.0.1"
        components.port = tunnel.localPort
        guard let localURL = components.url else {
            throw AgentBrowserDiscoveryError.tunnelFailed("The local CDP endpoint could not be created.")
        }
        return localURL
    }

    private static func makeTunnel(host: String, remotePort: Int) async throws -> Tunnel {

        let localPort = try Self.availableLoopbackPort()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
            "--", host
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AgentBrowserDiscoveryError.tunnelFailed(error.localizedDescription)
        }

        try await Task.sleep(for: .milliseconds(350))
        guard process.isRunning else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentBrowserDiscoveryError.tunnelFailed(message ?? "SSH exited before forwarding the port.")
        }

        return Tunnel(
            process: process,
            standardError: errorPipe,
            host: host,
            remotePort: remotePort,
            localPort: localPort
        )
    }

    func stop(for sessionID: BrowserSession.ID) {
        stopStream(for: sessionID)
        stopCDP(for: sessionID)
    }

    private func stopStream(for sessionID: BrowserSession.ID) {
        guard let tunnel = streamTunnels.removeValue(forKey: sessionID) else { return }
        Self.stop(tunnel)
    }

    private func stopCDP(for sessionID: BrowserSession.ID) {
        guard let tunnel = cdpTunnels.removeValue(forKey: sessionID) else { return }
        Self.stop(tunnel)
    }

    private static func stop(_ tunnel: Tunnel) {
        if tunnel.process.isRunning { tunnel.process.terminate() }
        tunnel.standardError.fileHandleForReading.closeFile()
    }

    func stopAll() {
        let ids = Set(streamTunnels.keys).union(cdpTunnels.keys)
        for id in ids { stop(for: id) }
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AgentBrowserDiscoveryError.tunnelFailed("A local port could not be allocated.")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw AgentBrowserDiscoveryError.tunnelFailed("A local port could not be reserved.")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw AgentBrowserDiscoveryError.tunnelFailed("The allocated local port could not be read.")
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw AgentBrowserDiscoveryError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let error = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentBrowserDiscoveryError.commandFailed(
                error?.isEmpty == false ? error! : "Agent Browser exited with status \(process.terminationStatus)."
            )
        }
        return output
    }
}
