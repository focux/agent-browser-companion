import Darwin
import Foundation

enum CDPNavigationClient {
    static func capabilities(
        browserURL: URL,
        activePageURL: URL?
    ) async throws -> AgentBrowserNavigationCapabilities {
        let targets = try await pageTargets(browserURL: browserURL)
        guard let target = preferredTarget(in: targets, activePageURL: activePageURL),
              let remoteWebSocketURL = URL(string: target.webSocketDebuggerUrl),
              let pageWebSocketURL = rebased(remoteWebSocketURL, through: browserURL) else {
            throw CDPNavigationError.pageTargetUnavailable
        }

        let command = try JSONSerialization.data(withJSONObject: [
            "id": 1,
            "method": "Page.getNavigationHistory"
        ])
        let responseData = try await Task.detached(priority: .utility) {
            let socket = try CDPSocket(url: pageWebSocketURL)
            defer { socket.close() }
            try socket.sendText(command)
            for _ in 0..<8 {
                let data = try socket.receiveMessage()
                if let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data),
                   envelope.id == 1 {
                    return data
                }
            }
            throw CDPNavigationError.malformedResponse
        }.value
        let response = try JSONDecoder().decode(HistoryResponse.self, from: responseData)
        guard let result = response.result else {
            throw CDPNavigationError.commandFailed
        }
        return AgentBrowserNavigationCapabilities(
            canGoBack: result.currentIndex > 0,
            canGoForward: result.currentIndex < result.entries.count - 1
        )
    }

    private static func pageTargets(browserURL: URL) async throws -> [Target] {
        guard var components = URLComponents(url: browserURL, resolvingAgainstBaseURL: false) else {
            throw CDPNavigationError.invalidEndpoint
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/json/list"
        components.query = nil
        components.fragment = nil
        guard let listURL = components.url else { throw CDPNavigationError.invalidEndpoint }
        let (data, response) = try await URLSession.shared.data(from: listURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CDPNavigationError.pageTargetUnavailable
        }
        return try JSONDecoder().decode([Target].self, from: data)
    }

    private static func preferredTarget(in targets: [Target], activePageURL: URL?) -> Target? {
        let pages = targets.filter { $0.type == "page" }
        if let activePageURL,
           let exact = pages.first(where: { URL(string: $0.url) == activePageURL }) {
            return exact
        }
        return pages.first { !$0.url.hasPrefix("chrome://") } ?? pages.first
    }

    private static func rebased(_ targetURL: URL, through browserURL: URL) -> URL? {
        guard var target = URLComponents(url: targetURL, resolvingAgainstBaseURL: false),
              let browser = URLComponents(url: browserURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // `/json/list` can report an HTTP(S) debugger URL even though the page
        // endpoint must be opened as a WebSocket. Preserve TLS, but always use
        // a WebSocket scheme after rebasing through a local SSH tunnel.
        target.scheme = browser.scheme == "wss" || browser.scheme == "https" ? "wss" : "ws"
        target.host = browser.host
        target.port = browser.port
        return target.url
    }

    private struct Target: Decodable {
        let type: String
        let url: String
        let webSocketDebuggerUrl: String
    }

    private struct HistoryResponse: Decodable {
        let result: HistoryResult?
    }

    private struct ResponseEnvelope: Decodable {
        let id: Int?
    }

    private struct HistoryResult: Decodable {
        let currentIndex: Int
        let entries: [NavigationEntry]
    }

    private struct NavigationEntry: Decodable {}
}

private enum CDPNavigationError: Error {
    case invalidEndpoint
    case pageTargetUnavailable
    case malformedResponse
    case commandFailed
    case timeout
    case unsupportedTransport
}

/// Chrome rejects Foundation's automatic WebSocket `Origin` unless it was
/// launched with a permissive flag. CDP's loopback endpoint expects clients
/// without an Origin, so this deliberately small RFC 6455 client is used only
/// for the single navigation-history command over local/SSH-forwarded `ws`.
private final class CDPSocket {
    private var descriptor: Int32 = -1
    private var buffered = Data()

    init(url: URL) throws {
        guard url.scheme == "ws",
              let host = url.host,
              let port = url.port,
              host == "127.0.0.1" || host == "localhost" else {
            throw CDPNavigationError.unsupportedTransport
        }

        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CDPNavigationError.pageTargetUnavailable }

        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &address.sin_addr) == 1 else {
            throw CDPNavigationError.invalidEndpoint
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw CDPNavigationError.pageTargetUnavailable }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?\(query)" }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let handshake = "GET \(path) HTTP/1.1\r\n"
            + "Host: \(host):\(port)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        try writeAll(Data(handshake.utf8))
        try readHandshake()
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    func sendText(_ payload: Data) throws {
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count) | 0x80)
        } else {
            frame.append(126 | 0x80)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try writeAll(frame)
    }

    func receiveMessage() throws -> Data {
        let header = try readExactly(2)
        let opcode = header[0] & 0x0F
        guard opcode == 1 || opcode == 2 else {
            throw CDPNavigationError.malformedResponse
        }
        let isMasked = header[1] & 0x80 != 0
        var length = Int(header[1] & 0x7F)
        if length == 126 {
            let extended = try readExactly(2)
            length = Int(UInt16(extended[0]) << 8 | UInt16(extended[1]))
        } else if length == 127 {
            let extended = try readExactly(8)
            length = extended.reduce(0) { ($0 << 8) | Int($1) }
        }
        let mask = isMasked ? Array(try readExactly(4)) : []
        let payload = try readExactly(length)
        guard isMasked else { return payload }
        return Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    private func readHandshake() throws {
        let marker = Data("\r\n\r\n".utf8)
        while buffered.range(of: marker) == nil { try readMore() }
        guard let range = buffered.range(of: marker) else { throw CDPNavigationError.malformedResponse }
        let header = buffered[..<range.upperBound]
        buffered.removeSubrange(..<range.upperBound)
        guard String(decoding: header, as: UTF8.self).hasPrefix("HTTP/1.1 101") else {
            throw CDPNavigationError.pageTargetUnavailable
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        while buffered.count < count { try readMore() }
        let result = buffered.prefix(count)
        buffered.removeFirst(count)
        return Data(result)
    }

    private func readMore() throws {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw CDPNavigationError.timeout }
            throw CDPNavigationError.pageTargetUnavailable
        }
        buffered.append(contentsOf: bytes.prefix(count))
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while sent < data.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else { throw CDPNavigationError.pageTargetUnavailable }
                sent += count
            }
        }
    }
}
