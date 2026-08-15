import AppKit
import Combine
import Foundation

@MainActor
final class AgentBrowserStream: ObservableObject, Identifiable {
    let id: BrowserSession.ID
    let session: BrowserSession

    @Published private(set) var connectionState: StreamConnectionState = .disconnected
    @Published private(set) var streamStatus = StreamStatus()
    @Published private(set) var currentFrame: BrowserFrame?
    @Published private(set) var frameAge: TimeInterval?
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var roundTripLatency: TimeInterval?
    @Published private(set) var lastEventDescription: String?
    @Published private(set) var pageURL: URL?
    @Published private(set) var supportsClientStreamConfiguration = false
    @Published private(set) var hasReceivedStatus = false

    private var socket: URLSessionWebSocketTask?
    private var sessionDelegate: WebSocketDelegate?
    private var urlSession: URLSession?
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var frameTimes: [TimeInterval] = []
    private var lastAcknowledgedSequence = -1
    private var lastReceivedSequence = -1
    private var fallbackFrameSequence = 0
    private var configuredMaxFPS = 30
    private var configuredPacing: StreamPacing = .acknowledgement
    private var pausesFrameDelivery = false
    private var usesLegacyFrameProtocol = false
    private var connectionGeneration = 0
    private var lastFrameReceivedAt: Date?
    private var lastLatencyProbeAt: TimeInterval = 0
    private var isLatencyProbeInFlight = false
    private var metricsTimer: AnyCancellable?

    init(session: BrowserSession) {
        id = session.id
        self.session = session
        supportsClientStreamConfiguration = session.agentBrowserSource != nil
        metricsTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshFrameMetrics() }
            }
    }

    var isBrowserAvailable: Bool {
        guard connectionState == .connected else { return false }
        if hasReceivedStatus {
            return streamStatus.browserConnected && streamStatus.screencasting
        }
        return currentFrame != nil
    }

    var effectiveStatusLabel: String {
        switch connectionState {
        case .disconnected: return "Offline"
        case .connecting: return "Connecting"
        case .failed: return "Connection failed"
        case .connected:
            if hasReceivedStatus {
                if !streamStatus.browserConnected { return "Browser unavailable" }
                return streamStatus.screencasting ? "Live" : "Waiting for video"
            }
            return currentFrame == nil ? "Connected" : "Live"
        }
    }

    func connect(maxFPS: Int, pacing: StreamPacing, pausesFrameDelivery: Bool = false) {
        configuredMaxFPS = min(max(maxFPS, 0), 120)
        configuredPacing = pacing
        self.pausesFrameDelivery = pausesFrameDelivery
        disconnect(allowReconnect: false)
        resetStreamState()
        let generation = connectionGeneration
        guard let url = configuredURL(maxFPS: configuredMaxFPS, pacing: pacing) else {
            connectionState = .failed("The stream URL is invalid.")
            return
        }

        shouldReconnect = true
        connectionState = .connecting
        let delegate = WebSocketDelegate()
        delegate.onOpen = { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                self.connectionState = .connected
                self.reconnectAttempt = 0
                self.configure(
                    maxFPS: self.configuredMaxFPS,
                    pacing: self.configuredPacing,
                    pausesFrameDelivery: self.pausesFrameDelivery
                )
            }
        }
        delegate.onClose = { [weak self] reason in
            Task { @MainActor in self?.socketClosed(reason: reason, generation: generation) }
        }
        sessionDelegate = delegate

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = true
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.urlSession = urlSession
        let socket = urlSession.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        receiveNext(generation: generation)
    }

    func disconnect() {
        disconnect(allowReconnect: false)
    }

    func configure(
        maxFPS: Int,
        pacing: StreamPacing,
        pausesFrameDelivery: Bool = false
    ) {
        let wasPaused = self.pausesFrameDelivery
        configuredMaxFPS = min(max(maxFPS, 0), 120)
        configuredPacing = pacing
        self.pausesFrameDelivery = pausesFrameDelivery
        send(AgentBrowserOutgoingMessage.config(maxFPS: configuredMaxFPS, pacing: pacing))
        if wasPaused, !pausesFrameDelivery, lastReceivedSequence >= 0 {
            acknowledge(sequence: lastReceivedSequence)
        }
    }

    func applyRuntimeStatus(_ status: AgentBrowserRuntimeStatus) {
        hasReceivedStatus = true
        var updatedStatus = streamStatus
        updatedStatus.browserConnected = status.browserConnected
        updatedStatus.screencasting = status.streamingEnabled && status.screencasting
        if updatedStatus != streamStatus {
            streamStatus = updatedStatus
        }
        if !status.browserConnected {
            frameTimes.removeAll()
            framesPerSecond = 0
        }
    }

    func acknowledge(sequence: Int) {
        guard !usesLegacyFrameProtocol else { return }
        guard sequence > lastAcknowledgedSequence else { return }
        lastAcknowledgedSequence = sequence
        send(AgentBrowserOutgoingMessage.acknowledgement(sequence: sequence))
    }

    func sendMouse(
        type: String,
        point: CGPoint,
        button: String? = nil,
        clickCount: Int? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        modifiers: Int = 0
    ) {
        send(AgentBrowserOutgoingMessage.mouse(
            type: type,
            x: point.x,
            y: point.y,
            button: button,
            clickCount: clickCount,
            deltaX: deltaX,
            deltaY: deltaY,
            modifiers: modifiers
        ))
    }

    func sendKey(type: String, key: String, code: String, text: String? = nil, modifiers: Int = 0) {
        send(AgentBrowserOutgoingMessage.keyboard(
            type: type,
            key: key,
            code: code,
            text: text,
            modifiers: modifiers
        ))
    }

    func sendCharacter(_ character: String) {
        if usesLegacyFrameProtocol {
            let key = character.lowercased()
            let code: String
            if let scalar = key.first, scalar.isLetter {
                code = "Key\(String(scalar).uppercased())"
            } else if let scalar = key.first, scalar.isNumber {
                code = "Digit\(scalar)"
            } else {
                code = key
            }
            send(AgentBrowserOutgoingMessage.keyboard(
                type: "keyDown",
                key: key,
                code: code,
                text: character
            ))
            send(AgentBrowserOutgoingMessage.keyboard(type: "keyUp", key: key, code: code))
        } else {
            send(AgentBrowserOutgoingMessage.keyboard(type: "char", text: character))
        }
    }

    func sendTouch(type: String, points: [RemoteTouchPoint]) {
        send(AgentBrowserOutgoingMessage.touch(type: type, points: points))
    }

    private func configuredURL(maxFPS: Int, pacing: StreamPacing) -> URL? {
        guard var components = URLComponents(string: session.endpoint) else { return nil }
        var query = components.queryItems ?? []
        query.removeAll { ["pacing", "maxFps"].contains($0.name) }
        query.append(URLQueryItem(name: "pacing", value: pacing.rawValue))
        query.append(URLQueryItem(name: "maxFps", value: String(maxFPS)))
        components.queryItems = query
        return components.url
    }

    private func disconnect(allowReconnect: Bool) {
        connectionGeneration += 1
        shouldReconnect = allowReconnect
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        if !allowReconnect {
            connectionState = .disconnected
            resetStreamState()
        }
    }

    private func receiveNext(generation: Int) {
        guard generation == connectionGeneration else { return }
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let rawData): data = rawData
                case .string(let string): data = string.data(using: .utf8)
                @unknown default: data = nil
                }
                if let data {
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.connectionGeneration else { return }
                        let decodesFrames = !self.pausesFrameDelivery || self.currentFrame == nil
                        let parsed = await Task.detached(priority: .userInitiated) {
                            AgentBrowserMessageParser.parse(data, decodesFrames: decodesFrames)
                        }.value
                        guard generation == self.connectionGeneration else { return }
                        self.handle(parsed)
                        self.receiveNext(generation: generation)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.receiveNext(generation: generation)
                    }
                }

            case .failure(let error):
                Task { @MainActor in
                    self.socketClosed(reason: error.localizedDescription, generation: generation)
                }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func measureRoundTripLatency(startedAt: TimeInterval) {
        guard connectionState == .connected,
              let socket,
              !isLatencyProbeInFlight else { return }
        let generation = connectionGeneration
        isLatencyProbeInFlight = true
        lastLatencyProbeAt = startedAt
        socket.sendPing { [weak self] error in
            let elapsed = max(
                ProcessInfo.processInfo.systemUptime - startedAt,
                0
            )
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                self.isLatencyProbeInFlight = false
                guard error == nil else {
                    self.roundTripLatency = nil
                    return
                }
                self.roundTripLatency = elapsed
            }
        }
    }

    private func handle(_ message: ParsedStreamMessage?) {
        guard let message else { return }
        switch message {
        case .frame(let frame):
            let presentedFrame: BrowserFrame
            if frame.sequence < 0 {
                usesLegacyFrameProtocol = true
                supportsClientStreamConfiguration = session.agentBrowserSource != nil
                fallbackFrameSequence += 1
                presentedFrame = BrowserFrame(
                    sequence: fallbackFrameSequence,
                    image: frame.image,
                    metadata: frame.metadata
                )
            } else {
                guard frame.sequence > lastReceivedSequence else { return }
                lastReceivedSequence = frame.sequence
                usesLegacyFrameProtocol = false
                supportsClientStreamConfiguration = true
                presentedFrame = frame
            }
            currentFrame = presentedFrame
            // Ack once the frame has been decoded and accepted by the app. Tying
            // transport flow control to MTKView drawable availability can stall
            // the stream while a window is resizing, occluded, or moving between
            // displays, even though the newest frame is already ready to present.
            if !pausesFrameDelivery {
                acknowledge(sequence: presentedFrame.sequence)
            }
            lastFrameReceivedAt = .now
            frameAge = 0
            let now = ProcessInfo.processInfo.systemUptime
            frameTimes.append(now)
            frameTimes.removeAll { now - $0 > 1 }
            framesPerSecond = Double(frameTimes.count)

        case .discardedFrame(let sequence):
            guard sequence >= 0 else { break }
            lastReceivedSequence = max(lastReceivedSequence, sequence)
            if !pausesFrameDelivery {
                acknowledge(sequence: sequence)
            }

        case .status(let status):
            hasReceivedStatus = true
            streamStatus = status

        case .event(let type, let payload):
            lastEventDescription = type.replacingOccurrences(of: "_", with: " ").capitalized
            if type == "tabs",
               let tabs = payload["tabs"] as? [[String: Any]],
               let activeTab = tabs.first(where: { $0["active"] as? Bool == true }),
               let value = activeTab["url"] as? String {
                pageURL = URL(string: value)
            } else if type == "url", let value = payload["url"] as? String {
                pageURL = URL(string: value)
            }
        }
    }

    private func socketClosed(reason: String?, generation: Int) {
        guard generation == connectionGeneration, shouldReconnect, socket != nil else { return }
        connectionState = .failed(reason ?? "The connection closed.")
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        streamStatus = StreamStatus()
        currentFrame = nil
        frameAge = nil
        framesPerSecond = 0
        roundTripLatency = nil
        frameTimes.removeAll()
        isLatencyProbeInFlight = false
        lastLatencyProbeAt = 0
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt)), 12)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  generation == self.connectionGeneration,
                  self.shouldReconnect else { return }
            self.connect(
                maxFPS: self.configuredMaxFPS,
                pacing: self.configuredPacing,
                pausesFrameDelivery: self.pausesFrameDelivery
            )
        }
    }

    private func resetStreamState() {
        streamStatus = StreamStatus()
        currentFrame = nil
        frameAge = nil
        framesPerSecond = 0
        roundTripLatency = nil
        lastFrameReceivedAt = nil
        lastLatencyProbeAt = 0
        isLatencyProbeInFlight = false
        lastEventDescription = nil
        pageURL = nil
        supportsClientStreamConfiguration = session.agentBrowserSource != nil
        hasReceivedStatus = false
        frameTimes.removeAll()
        lastAcknowledgedSequence = -1
        lastReceivedSequence = -1
        fallbackFrameSequence = 0
        usesLegacyFrameProtocol = false
    }

    private func refreshFrameMetrics() {
        let now = ProcessInfo.processInfo.systemUptime
        frameTimes.removeAll { now - $0 > 1 }
        framesPerSecond = Double(frameTimes.count)
        if let lastFrameReceivedAt {
            frameAge = Date().timeIntervalSince(lastFrameReceivedAt)
        }
        if connectionState == .connected,
           !isLatencyProbeInFlight,
           now - lastLatencyProbeAt >= 2 {
            measureRoundTripLatency(startedAt: now)
        }
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((String?) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(reason.flatMap { String(data: $0, encoding: .utf8) })
    }
}
