import AppKit
import Foundation
import ImageIO

enum AgentBrowserMessageParser {
    static func parse(_ data: Data, decodesFrames: Bool = true) -> ParsedStreamMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "frame":
            let sequence = number(object["seq"])?.intValue ?? -1
            guard decodesFrames else { return .discardedFrame(sequence: sequence) }
            guard let encoded = object["data"] as? String,
                  let imageData = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let metadataObject = object["metadata"] as? [String: Any] ?? [:]
            let metadata = StreamMetadata(
                deviceWidth: number(metadataObject["deviceWidth"])?.intValue ?? image.width,
                deviceHeight: number(metadataObject["deviceHeight"])?.intValue ?? image.height,
                pageScaleFactor: number(metadataObject["pageScaleFactor"])?.doubleValue ?? 1,
                offsetTop: number(metadataObject["offsetTop"])?.doubleValue ?? 0,
                scrollOffsetX: number(metadataObject["scrollOffsetX"])?.doubleValue ?? 0,
                scrollOffsetY: number(metadataObject["scrollOffsetY"])?.doubleValue ?? 0,
                timestamp: number(metadataObject["timestamp"])?.doubleValue ?? 0
            )
            return .frame(BrowserFrame(sequence: sequence, image: image, metadata: metadata))

        case "status":
            return .status(StreamStatus(
                browserConnected: object["connected"] as? Bool ?? false,
                screencasting: object["screencasting"] as? Bool ?? false,
                viewportWidth: number(object["viewportWidth"])?.intValue ?? 0,
                viewportHeight: number(object["viewportHeight"])?.intValue ?? 0
            ))

        default:
            return .event(type: type, payload: object)
        }
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}

enum ParsedStreamMessage {
    case frame(BrowserFrame)
    case discardedFrame(sequence: Int)
    case status(StreamStatus)
    case event(type: String, payload: [String: Any])
}

enum AgentBrowserOutgoingMessage {
    static func config(maxFPS: Int, pacing: StreamPacing) -> [String: Any] {
        ["type": "config", "maxFps": min(max(maxFPS, 0), 120), "pacing": pacing.rawValue]
    }

    static func acknowledgement(sequence: Int) -> [String: Any] {
        ["type": "ack", "seq": sequence]
    }

    static func mouse(
        type: String,
        x: Double,
        y: Double,
        button: String? = nil,
        clickCount: Int? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        modifiers: Int? = nil
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "input_mouse",
            "eventType": type,
            "x": x,
            "y": y
        ]
        if let button { message["button"] = button }
        if let clickCount { message["clickCount"] = clickCount }
        if let deltaX { message["deltaX"] = deltaX }
        if let deltaY { message["deltaY"] = deltaY }
        if let modifiers, modifiers > 0 { message["modifiers"] = modifiers }
        return message
    }

    static func keyboard(
        type: String,
        key: String? = nil,
        code: String? = nil,
        text: String? = nil,
        modifiers: Int? = nil
    ) -> [String: Any] {
        var message: [String: Any] = ["type": "input_keyboard", "eventType": type]
        if let key { message["key"] = key }
        if let code { message["code"] = code }
        if let text { message["text"] = text }
        if let modifiers, modifiers > 0 { message["modifiers"] = modifiers }
        return message
    }

    static func touch(type: String, points: [RemoteTouchPoint]) -> [String: Any] {
        [
            "type": "input_touch",
            "eventType": type,
            "touchPoints": points.map { point in
                var payload: [String: Any] = ["x": point.x, "y": point.y]
                if let id = point.id { payload["id"] = id }
                return payload
            }
        ]
    }
}

struct RemoteTouchPoint {
    let x: Double
    let y: Double
    let id: Int?

    init(x: Double, y: Double, id: Int? = nil) {
        self.x = x
        self.y = y
        self.id = id
    }
}
