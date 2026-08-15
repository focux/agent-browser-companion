import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class BrowserWorkspace: ObservableObject {
    @Published private(set) var sessions: [BrowserSession] = []
    @Published private(set) var savedSSHHosts: [String] = []
    @Published private(set) var isDiscoveringSessions = false
    @Published var selectedSessionID: BrowserSession.ID? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            updateStreamConfigurations()
        }
    }
    @Published var isSidebarVisible = true
    @Published var isInspectorVisible = true
    @Published var isPresentingHostManager = false
    @Published var presentedError: PresentedWorkspaceError?
    @Published private(set) var isRunningNavigationCommand = false
    @Published private var navigationCapabilities: [BrowserSession.ID: AgentBrowserNavigationCapabilities] = [:]
    @Published private(set) var pictureInPictureSessionIDs: [BrowserSession.ID] = []
    @Published var searchText = ""
    @Published var preferredFPS = 30 {
        didSet {
            let clamped = min(max(preferredFPS, 0), 120)
            guard preferredFPS == clamped else {
                preferredFPS = clamped
                return
            }
            guard preferredFPS != oldValue else { return }
            UserDefaults.standard.set(preferredFPS, forKey: Keys.preferredFPS)
            updateStreamConfigurations()
        }
    }
    @Published var pacing: StreamPacing = .acknowledgement {
        didSet {
            guard pacing != oldValue else { return }
            UserDefaults.standard.set(pacing.rawValue, forKey: Keys.pacing)
            updateStreamConfigurations()
        }
    }

    private var clients: [BrowserSession.ID: AgentBrowserStream] = [:]
    private var clientStatusObservers: [BrowserSession.ID: AnyCancellable] = [:]
    private var pictureInPictureController: PictureInPictureWindowController?
    private let tunnelManager = SSHTunnelManager()
    private var terminationObserver: AnyCancellable?
    private var localDiscoveryObserver: AnyCancellable?
    private var remoteDiscoveryObserver: AnyCancellable?
    private var discoveringTargets = Set<AgentBrowserDiscoveryTarget>()
    private var missingDiscoveryPasses: [String: Int] = [:]
    private var persistedSessionCache: [String: BrowserSession] = [:]
    private var legacySessionCache: [BrowserSession] = []
    private var browserStageSize: CGSize?
    private var viewportSyncTask: Task<Void, Never>?
    private var lastRequestedViewports: [BrowserSession.ID: BrowserViewportSize] = [:]
    private var lastObservedViewports: [BrowserSession.ID: BrowserViewportSize] = [:]
    private var sidebarPreviewSessionID: BrowserSession.ID?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        var persistedSessions: [BrowserSession] = []
        if let data = UserDefaults.standard.data(forKey: Keys.sessions),
           let decoded = try? decoder.decode([BrowserSession].self, from: data) {
            persistedSessions = decoded
            persistedSessionCache = Dictionary(
                decoded.compactMap { session in
                    session.agentBrowserSource.map { ($0.identity, session) }
                },
                uniquingKeysWith: { current, _ in current }
            )
            legacySessionCache = decoded.filter { $0.agentBrowserSource == nil }
        }

        let storedHosts = UserDefaults.standard.stringArray(forKey: Keys.sshHosts) ?? []
        savedSSHHosts = DiscoveryTargetCatalog.normalizedSSHHosts(
            storedHosts + DiscoveryTargetCatalog.migratedSSHHosts(from: persistedSessions)
        )
        UserDefaults.standard.set(savedSSHHosts, forKey: Keys.sshHosts)

        if UserDefaults.standard.object(forKey: Keys.preferredFPS) != nil {
            preferredFPS = min(max(UserDefaults.standard.integer(forKey: Keys.preferredFPS), 0), 120)
        }
        if let rawPacing = UserDefaults.standard.string(forKey: Keys.pacing),
           let storedPacing = StreamPacing(rawValue: rawPacing) {
            pacing = storedPacing
        }

        terminationObserver = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak tunnelManager] _ in
                tunnelManager?.stopAll()
            }

        localDiscoveryObserver = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshDiscoveredSessions(on: [.local])
                }
            }

        remoteDiscoveryObserver = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.refreshDiscoveredSessions(
                        on: self.knownDiscoveryTargets.filter { target in
                            if case .ssh = target { return true }
                            return false
                        }
                    )
                }
            }
    }

    var selectedSession: BrowserSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selectedClient: AgentBrowserStream? {
        selectedSessionID.flatMap { clients[$0] }
    }

    var canNavigateSelectedSession: Bool {
        selectedSession?.agentBrowserSource != nil && selectedClient?.isBrowserAvailable == true
    }

    var canGoBack: Bool {
        selectedSessionID.flatMap { navigationCapabilities[$0] }?.canGoBack == true
    }

    var canGoForward: Bool {
        selectedSessionID.flatMap { navigationCapabilities[$0] }?.canGoForward == true
    }

    var isPictureInPictureVisible: Bool {
        !pictureInPictureSessionIDs.isEmpty
    }

    var isSelectedSessionInPictureInPicture: Bool {
        selectedSessionID.map(pictureInPictureSessionIDs.contains) ?? false
    }

    var pictureInPictureSessions: [BrowserSession] {
        pictureInPictureSessionIDs.compactMap { id in
            sessions.first { $0.id == id }
        }
    }

    var filteredSessions: [BrowserSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                || $0.endpoint.localizedCaseInsensitiveContains(searchText)
                || ($0.agentBrowserSource?.sessionName.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    var groupedFilteredSessions: [(hostname: String, sessions: [BrowserSession])] {
        Dictionary(grouping: filteredSessions, by: \.hostname)
            .map { (hostname: $0.key, sessions: $0.value) }
            .sorted { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }
    }

    var knownDiscoveryTargets: [AgentBrowserDiscoveryTarget] {
        DiscoveryTargetCatalog.knownTargets(sshHosts: savedSSHHosts)
    }

    func client(for session: BrowserSession) -> AgentBrowserStream {
        if let client = clients[session.id] { return client }
        let client = AgentBrowserStream(session: session)
        clients[session.id] = client
        observeViewportStatus(of: client, sessionID: session.id)
        return client
    }

    func addSSHHost(_ rawHost: String) throws {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentBrowserDiscoveryService.isValidSSHHost(host) else {
            throw AgentBrowserDiscoveryError.invalidSSHHost
        }
        guard !savedSSHHosts.contains(where: {
            $0.caseInsensitiveCompare(host) == .orderedSame
        }) else { return }

        savedSSHHosts.append(host)
        savedSSHHosts = DiscoveryTargetCatalog.normalizedSSHHosts(savedSSHHosts)
        saveHosts()

        Task { await refreshDiscoveredSessions(on: [.ssh(host)]) }
    }

    func removeSSHHost(_ host: String) {
        savedSSHHosts.removeAll { $0.caseInsensitiveCompare(host) == .orderedSame }
        saveHosts()

        let hostSessions = sessions.filter { session in
            guard session.agentBrowserSource?.location == .ssh,
                  let sessionHost = session.agentBrowserSource?.sshHost else { return false }
            return sessionHost.caseInsensitiveCompare(host) == .orderedSame
        }
        for session in hostSessions {
            removeSession(session, keepsCachedMetadata: false)
        }
        persistedSessionCache = persistedSessionCache.filter { _, session in
            guard session.agentBrowserSource?.location == .ssh,
                  let sessionHost = session.agentBrowserSource?.sshHost else { return true }
            return sessionHost.caseInsensitiveCompare(host) != .orderedSame
        }
        saveSessionCache()
    }

    func removeSSHHost(for session: BrowserSession) {
        guard let source = session.agentBrowserSource,
              source.location == .ssh,
              let host = source.sshHost else { return }
        removeSSHHost(host)
    }

    func sessionCount(forSSHHost host: String) -> Int {
        sessions.count { session in
            guard session.agentBrowserSource?.location == .ssh,
                  let sessionHost = session.agentBrowserSource?.sshHost else { return false }
            return sessionHost.caseInsensitiveCompare(host) == .orderedSame
        }
    }

    func reconnectAll() {
        Task {
            for session in sessions {
                await reconnect(session, presentsErrors: false)
            }
        }
    }

    func startAutomaticDiscovery() async {
        await refreshDiscoveredSessions(on: knownDiscoveryTargets)
    }

    func refreshDiscoveredSessions() {
        Task { await refreshDiscoveredSessions(on: knownDiscoveryTargets) }
    }

    func reconnectSelected() {
        guard let session = selectedSession else { return }
        Task { await reconnect(session, presentsErrors: true) }
    }

    func reconnect(_ session: BrowserSession) {
        Task { await reconnect(session, presentsErrors: true) }
    }

    private func reconnect(_ session: BrowserSession, presentsErrors: Bool) async {
        do {
            try await prepareAgentBrowserSessionIfNeeded(session.id)
            guard let refreshed = sessions.first(where: { $0.id == session.id }) else { return }
            connectStream(for: refreshed)
        } catch {
            if presentsErrors { present(error) }
        }
    }

    func runNavigationCommand(_ command: AgentBrowserNavigationCommand) {
        guard let session = selectedSession,
              let source = session.agentBrowserSource else { return }
        let sessionID = session.id
        Task {
            isRunningNavigationCommand = true
            defer { isRunningNavigationCommand = false }
            do {
                try await AgentBrowserDiscoveryService.run(command, for: source)
                try? await Task.sleep(for: .milliseconds(180))
                await refreshNavigationCapabilities(for: sessionID)
            } catch {
                present(error)
            }
        }
    }

    func refreshSelectedNavigationCapabilities() async {
        await refreshNavigationCapabilities(for: selectedSessionID)
    }

    func setViewport(_ viewport: BrowserViewportSize, for sessionID: BrowserSession.ID) async -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let source = session.agentBrowserSource,
              clients[sessionID]?.isBrowserAvailable == true else {
            return false
        }
        do {
            try await AgentBrowserDiscoveryService.setViewport(
                width: viewport.width,
                height: viewport.height,
                for: source
            )
            return true
        } catch {
            return false
        }
    }

    func updateBrowserStageSize(_ size: CGSize) {
        let normalized = CGSize(
            width: size.width.rounded(.down),
            height: size.height.rounded(.down)
        )
        guard normalized.width >= 320,
              normalized.height >= 240,
              normalized != browserStageSize else { return }
        browserStageSize = normalized
        scheduleViewportSynchronization()
    }

    func setSidebarPreviewSession(_ sessionID: BrowserSession.ID?) {
        guard sidebarPreviewSessionID != sessionID else { return }
        sidebarPreviewSessionID = sessionID
        updateStreamConfigurations()
    }

    func connectStream(for session: BrowserSession) {
        let configuration = streamConfiguration(for: session.id)
        client(for: session).connect(
            maxFPS: configuration.maxFPS,
            pacing: configuration.pacing,
            pausesFrameDelivery: configuration.pausesFrameDelivery
        )
    }

    func streamConfiguration(for sessionID: BrowserSession.ID) -> StreamClientConfiguration {
        StreamActivityPolicy.configuration(
            preferredFPS: preferredFPS,
            preferredPacing: pacing,
            isForeground: selectedSessionID == sessionID
                || pictureInPictureSessionIDs.contains(sessionID),
            isPreviewing: sidebarPreviewSessionID == sessionID
        )
    }

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.28)) { isSidebarVisible.toggle() }
    }

    func toggleInspector() {
        withAnimation(.snappy(duration: 0.28)) { isInspectorVisible.toggle() }
    }

    func togglePictureInPicture() {
        guard let selectedSessionID else { return }
        if pictureInPictureSessionIDs.contains(selectedSessionID) {
            removeFromPictureInPicture(selectedSessionID)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 1)) {
                pictureInPictureSessionIDs.append(selectedSessionID)
            }
            updateStreamConfigurations()
            showPictureInPictureWindowIfNeeded()
        }
    }

    func bringPictureInPictureSessionToFront(_ id: BrowserSession.ID) {
        guard let index = pictureInPictureSessionIDs.firstIndex(of: id),
              index != pictureInPictureSessionIDs.indices.last else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
            pictureInPictureSessionIDs.remove(at: index)
            pictureInPictureSessionIDs.append(id)
        }
    }

    func removeFromPictureInPicture(_ id: BrowserSession.ID) {
        guard pictureInPictureSessionIDs.contains(id) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
            pictureInPictureSessionIDs.removeAll { $0 == id }
        }
        updateStreamConfigurations()
        if pictureInPictureSessionIDs.isEmpty {
            pictureInPictureController?.close()
            pictureInPictureController = nil
        }
    }

    private func showPictureInPictureWindowIfNeeded() {
        if let pictureInPictureController {
            pictureInPictureController.showWindow(nil)
            return
        }
        let controller = PictureInPictureWindowController(workspace: self) { [weak self] in
            guard let self else { return }
            self.pictureInPictureController = nil
            self.pictureInPictureSessionIDs.removeAll()
            self.updateStreamConfigurations()
        }
        pictureInPictureController = controller
        controller.showWindow(nil)
    }

    private func prepareAgentBrowserSessionIfNeeded(_ id: BrowserSession.ID) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let source = sessions[index].agentBrowserSource else { return }
        let refreshed = try await AgentBrowserDiscoveryService.refreshedSource(source)
        let endpoint: String
        switch refreshed.location {
        case .local:
            endpoint = "ws://127.0.0.1:\(refreshed.streamPort)"
        case .ssh:
            guard let host = refreshed.sshHost else {
                throw AgentBrowserDiscoveryError.invalidSSHHost
            }
            endpoint = try await tunnelManager.open(for: id, host: host, remotePort: refreshed.streamPort)
        }

        clients[id]?.disconnect()
        clients[id] = nil
        clientStatusObservers[id] = nil
        lastRequestedViewports[id] = nil
        lastObservedViewports[id] = nil
        sessions[index].endpoint = EndpointNormalizer.normalize(endpoint)
        sessions[index].agentBrowserSource = refreshed
        save()
    }

    private func refreshNavigationCapabilities(for sessionID: BrowserSession.ID?) async {
        guard let sessionID,
              let source = sessions.first(where: { $0.id == sessionID })?.agentBrowserSource else {
            return
        }
        do {
            let context = try await AgentBrowserDiscoveryService.cdpContext(for: source)
            let browserURL: URL
            switch source.location {
            case .local:
                browserURL = context.browserURL
            case .ssh:
                guard let host = source.sshHost else {
                    throw AgentBrowserDiscoveryError.invalidSSHHost
                }
                browserURL = try await tunnelManager.cdpBrowserURL(
                    for: sessionID,
                    host: host,
                    remoteURL: context.browserURL
                )
            }
            navigationCapabilities[sessionID] = try await CDPNavigationClient.capabilities(
                browserURL: browserURL,
                activePageURL: context.activePageURL
            )
        } catch {
            navigationCapabilities[sessionID] = (try? await AgentBrowserDiscoveryService.navigationCapabilities(for: source))
                ?? AgentBrowserNavigationCapabilities()
        }
    }

    private func observeViewportStatus(
        of client: AgentBrowserStream,
        sessionID: BrowserSession.ID
    ) {
        clientStatusObservers[sessionID] = client.$connectionState
            .combineLatest(client.$streamStatus)
            .sink { [weak self, weak client] _, _ in
                Task { @MainActor [weak self, weak client] in
                    guard let self, let client, self.clients[sessionID] === client else { return }
                    self.viewportStatusDidChange(for: sessionID, client: client)
                }
            }
    }

    private func viewportStatusDidChange(
        for sessionID: BrowserSession.ID,
        client: AgentBrowserStream
    ) {
        guard client.isBrowserAvailable else {
            lastRequestedViewports[sessionID] = nil
            lastObservedViewports[sessionID] = nil
            return
        }
        guard client.streamStatus.viewportWidth > 0,
              client.streamStatus.viewportHeight > 0 else { return }

        let observedViewport = BrowserViewportSize(
            width: client.streamStatus.viewportWidth,
            height: client.streamStatus.viewportHeight
        )
        if lastObservedViewports[sessionID] != observedViewport {
            // A confirmed viewport change may be our previous request or an
            // external resize. In either case, compare it with the current
            // pane again instead of permanently suppressing the same command.
            lastObservedViewports[sessionID] = observedViewport
            lastRequestedViewports[sessionID] = nil
        }
        _ = minimumViewport(for: sessionID, client: client)
        scheduleViewportSynchronization()
    }

    private func scheduleViewportSynchronization() {
        guard browserStageSize != nil else { return }
        viewportSyncTask?.cancel()
        viewportSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            await self.synchronizeActiveViewports()
        }
    }

    private func synchronizeActiveViewports() async {
        guard let browserStageSize else { return }
        let sessionIDs = sessions.compactMap { session in
            session.agentBrowserSource == nil ? nil : session.id
        }

        // Apply commands serially. This prevents several SSH processes from
        // starting at once when a window opens or finishes resizing.
        for sessionID in sessionIDs {
            guard !Task.isCancelled,
                  let client = clients[sessionID],
                  client.isBrowserAvailable,
                  client.streamStatus.viewportWidth > 0,
                  client.streamStatus.viewportHeight > 0,
                  let minimumViewport = minimumViewport(for: sessionID, client: client),
                  let viewport = BrowserViewportSizing.viewport(
                    for: browserStageSize,
                    minimumWidth: minimumViewport.width,
                    minimumHeight: minimumViewport.height
                  ) else { continue }

            let observedViewport = BrowserViewportSize(
                width: client.streamStatus.viewportWidth,
                height: client.streamStatus.viewportHeight
            )
            if observedViewport == viewport {
                lastRequestedViewports[sessionID] = viewport
                continue
            }
            guard lastRequestedViewports[sessionID] != viewport else { continue }

            lastRequestedViewports[sessionID] = viewport
            let didApply = await setViewport(viewport, for: sessionID)
            if !didApply {
                lastRequestedViewports[sessionID] = nil
            }
        }
    }

    private func minimumViewport(
        for sessionID: BrowserSession.ID,
        client: AgentBrowserStream
    ) -> BrowserViewportSize? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        if let minimumViewport = sessions[index].minimumViewport {
            return minimumViewport
        }
        guard client.streamStatus.viewportWidth > 0,
              client.streamStatus.viewportHeight > 0 else { return nil }

        let minimumViewport = BrowserViewportSize(
            width: max(client.streamStatus.viewportWidth, 1_280),
            height: client.streamStatus.viewportHeight
        )
        sessions[index].minimumViewport = minimumViewport
        save()
        return minimumViewport
    }

    private func updateStreamConfigurations() {
        for (sessionID, client) in clients {
            let configuration = streamConfiguration(for: sessionID)
            client.configure(
                maxFPS: configuration.maxFPS,
                pacing: configuration.pacing,
                pausesFrameDelivery: configuration.pausesFrameDelivery
            )
        }
    }

    private func refreshDiscoveredSessions(on requestedTargets: [AgentBrowserDiscoveryTarget]) async {
        let knownTargets = Set(knownDiscoveryTargets)
        let targets = Array(Set(requestedTargets))
            .filter { knownTargets.contains($0) && !discoveringTargets.contains($0) }
        guard !targets.isEmpty else { return }

        discoveringTargets.formUnion(targets)
        isDiscoveringSessions = true

        let results = await withTaskGroup(of: TargetDiscoveryResult.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        return TargetDiscoveryResult(
                            target: target,
                            sessions: try await AgentBrowserDiscoveryService.discover(target)
                        )
                    } catch {
                        return TargetDiscoveryResult(target: target, sessions: nil)
                    }
                }
            }

            var results: [TargetDiscoveryResult] = []
            for await result in group { results.append(result) }
            return results
        }

        for result in results where Set(knownDiscoveryTargets).contains(result.target) {
            if let discovered = result.sessions {
                await reconcileDiscoveredSessions(discovered, for: result.target)
            }
        }

        discoveringTargets.subtract(targets)
        isDiscoveringSessions = !discoveringTargets.isEmpty
    }

    private func reconcileDiscoveredSessions(
        _ discoveredSessions: [DiscoveredAgentBrowserSession],
        for target: AgentBrowserDiscoveryTarget
    ) async {
        let available = discoveredSessions
            .filter { $0.browserConnected && $0.streamingEnabled }
            .sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        let availableIdentities = Set(available.map(\.source.identity))

        for discovered in available {
            missingDiscoveryPasses[discovered.source.identity] = nil
            try? await upsertDiscoveredSession(discovered)
        }

        let missing = sessions.filter { session in
            guard let source = session.agentBrowserSource,
                  source.matches(target) else { return false }
            return !availableIdentities.contains(source.identity)
        }
        for session in missing {
            guard let identity = session.agentBrowserSource?.identity else { continue }
            let count = AutomaticSessionRetention.nextMissingPassCount(
                previous: missingDiscoveryPasses[identity, default: 0],
                isPresent: false
            )
            missingDiscoveryPasses[identity] = count
            if AutomaticSessionRetention.shouldRemove(missingPassCount: count) {
                missingDiscoveryPasses[identity] = nil
                removeSession(session, keepsCachedMetadata: true)
            }
        }
    }

    private func upsertDiscoveredSession(_ discovered: DiscoveredAgentBrowserSession) async throws {
        let identity = discovered.source.identity
        if let index = sessions.firstIndex(where: {
            $0.agentBrowserSource?.identity == identity
        }) {
            let existing = sessions[index]
            let connectionChanged = existing.agentBrowserSource?.streamPort != discovered.source.streamPort
            if connectionChanged {
                let endpoint = try await endpoint(for: discovered.source, sessionID: existing.id)
                resetClient(for: existing.id)
                sessions[index].endpoint = EndpointNormalizer.normalize(endpoint)
            }
            sessions[index].agentBrowserSource = discovered.source
            sessions[index].activePageTitle = discovered.activePageTitle
            sessions[index].activePageURL = discovered.activePageURL
            sessions[index].automaticallyConnects = true
            save()

            let session = sessions[index]
            let stream = client(for: session)
            switch stream.connectionState {
            case .disconnected, .failed:
                connectStream(for: session)
            case .connecting, .connected:
                break
            }
            stream.applyRuntimeStatus(discovered.runtimeStatus)
            return
        }

        var session = cachedSession(for: discovered) ?? BrowserSession(
            endpoint: "",
            automaticallyConnects: true,
            agentBrowserSource: discovered.source
        )
        session.endpoint = EndpointNormalizer.normalize(
            try await endpoint(for: discovered.source, sessionID: session.id)
        )
        session.automaticallyConnects = true
        session.agentBrowserSource = discovered.source
        session.activePageTitle = discovered.activePageTitle
        session.activePageURL = discovered.activePageURL

        sessions.append(session)
        save()
        if selectedSessionID == nil { selectedSessionID = session.id }
        connectStream(for: session)
        client(for: session).applyRuntimeStatus(discovered.runtimeStatus)
    }

    private func cachedSession(for discovered: DiscoveredAgentBrowserSession) -> BrowserSession? {
        if let cached = persistedSessionCache[discovered.source.identity] {
            return cached
        }
        guard discovered.source.location == .local,
              let index = legacySessionCache.firstIndex(where: {
                  $0.unmanagedLoopbackStreamPort == discovered.source.streamPort
              }) else { return nil }
        return legacySessionCache.remove(at: index)
    }

    private func endpoint(for source: AgentBrowserSource, sessionID: BrowserSession.ID) async throws -> String {
        switch source.location {
        case .local:
            return "ws://127.0.0.1:\(source.streamPort)"
        case .ssh:
            guard let host = source.sshHost else {
                throw AgentBrowserDiscoveryError.invalidSSHHost
            }
            return try await tunnelManager.open(
                for: sessionID,
                host: host,
                remotePort: source.streamPort
            )
        }
    }

    private func resetClient(for id: BrowserSession.ID) {
        clients[id]?.disconnect()
        clients[id] = nil
        clientStatusObservers[id] = nil
        lastRequestedViewports[id] = nil
        lastObservedViewports[id] = nil
        navigationCapabilities[id] = nil
    }

    private func removeSession(_ session: BrowserSession, keepsCachedMetadata: Bool) {
        removeFromPictureInPicture(session.id)
        resetClient(for: session.id)
        tunnelManager.stop(for: session.id)
        sessions.removeAll { $0.id == session.id }

        if let identity = session.agentBrowserSource?.identity {
            if keepsCachedMetadata {
                persistedSessionCache[identity] = session
            } else {
                persistedSessionCache[identity] = nil
            }
        }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
        saveSessionCache()
    }

    private func present(_ error: Error) {
        presentedError = PresentedWorkspaceError(message: error.localizedDescription)
    }

    private func save() {
        for session in sessions {
            guard let identity = session.agentBrowserSource?.identity else { continue }
            persistedSessionCache[identity] = session
        }
        saveSessionCache()
    }

    private func saveSessionCache() {
        let cached = Array(persistedSessionCache.values) + legacySessionCache
        guard let data = try? encoder.encode(cached.sorted { $0.createdAt < $1.createdAt }) else { return }
        UserDefaults.standard.set(data, forKey: Keys.sessions)
    }

    private func saveHosts() {
        UserDefaults.standard.set(savedSSHHosts, forKey: Keys.sshHosts)
    }

    private struct TargetDiscoveryResult {
        let target: AgentBrowserDiscoveryTarget
        let sessions: [DiscoveredAgentBrowserSession]?
    }

    private enum Keys {
        static let sessions = "browserSessions.v1"
        static let sshHosts = "sshHosts.v1"
        static let preferredFPS = "preferredFPS"
        static let pacing = "streamPacing"
    }
}

struct PresentedWorkspaceError: Identifiable {
    let id = UUID()
    let message: String
}

enum EndpointNormalizer {
    static func normalize(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "ws://\(value)" }
        guard var components = URLComponents(string: value) else { return value }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }

        var query = components.queryItems ?? []
        if !query.contains(where: { $0.name == "pacing" }) {
            query.append(URLQueryItem(name: "pacing", value: "ack"))
        }
        components.queryItems = query
        return components.string ?? value
    }

    static func displayName(for endpoint: String) -> String {
        URL(string: endpoint)?.host?.components(separatedBy: ".").first?.capitalized ?? "Browser"
    }

    static func isValid(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard let url = URL(string: normalized) else { return false }
        return ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}
