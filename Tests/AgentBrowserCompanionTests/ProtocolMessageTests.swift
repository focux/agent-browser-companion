import Foundation
import ImageIO
import XCTest
@testable import AgentBrowserCompanion

final class ProtocolMessageTests: XCTestCase {
    func testCanDiscardABackgroundFrameWithoutDecodingItsImage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "frame",
            "seq": 42,
            "data": "this-does-not-need-to-be-a-valid-jpeg"
        ])

        let message = AgentBrowserMessageParser.parse(data, decodesFrames: false)

        guard case .discardedFrame(let sequence) = message else {
            return XCTFail("Expected a discarded frame marker.")
        }
        XCTAssertEqual(sequence, 42)
    }

    func testParsesStatusMessage() throws {
        let data = try XCTUnwrap(
            """
            {"type":"status","connected":true,"screencasting":true,"viewportWidth":1280,"viewportHeight":720}
            """.data(using: .utf8)
        )

        guard case .status(let status) = AgentBrowserMessageParser.parse(data) else {
            return XCTFail("Expected a status message")
        }
        XCTAssertTrue(status.browserConnected)
        XCTAssertTrue(status.screencasting)
        XCTAssertEqual(status.viewportWidth, 1280)
        XCTAssertEqual(status.viewportHeight, 720)
    }

    func testBuildsAcknowledgementMessage() {
        let message = AgentBrowserOutgoingMessage.acknowledgement(sequence: 41)
        XCTAssertEqual(message["type"] as? String, "ack")
        XCTAssertEqual(message["seq"] as? Int, 41)
    }

    func testBuildsProtocolModifierMask() {
        let message = AgentBrowserOutgoingMessage.keyboard(
            type: "keyDown",
            key: "c",
            code: "KeyC",
            modifiers: 6
        )
        XCTAssertEqual(message["type"] as? String, "input_keyboard")
        XCTAssertEqual(message["eventType"] as? String, "keyDown")
        XCTAssertEqual(message["modifiers"] as? Int, 6)
    }

    func testClampsFrameRateToProtocolRange() {
        XCTAssertEqual(
            AgentBrowserOutgoingMessage.config(maxFPS: -1, pacing: .acknowledgement)["maxFps"] as? Int,
            0
        )
        XCTAssertEqual(
            AgentBrowserOutgoingMessage.config(maxFPS: 121, pacing: .push)["maxFps"] as? Int,
            120
        )
    }

    func testBuildsMultiTouchMessage() throws {
        let message = AgentBrowserOutgoingMessage.touch(type: "touchStart", points: [
            RemoteTouchPoint(x: 100, y: 200, id: 0),
            RemoteTouchPoint(x: 240, y: 200, id: 1)
        ])

        XCTAssertEqual(message["type"] as? String, "input_touch")
        XCTAssertEqual(message["eventType"] as? String, "touchStart")
        let points = try XCTUnwrap(message["touchPoints"] as? [[String: Any]])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0]["x"] as? Double, 100)
        XCTAssertEqual(points[0]["id"] as? Int, 0)
        XCTAssertEqual(points[1]["x"] as? Double, 240)
        XCTAssertEqual(points[1]["id"] as? Int, 1)
    }

    func testParsesLegacyJPEGFrameWithoutSequence() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixels: [UInt8] = [
            0, 122, 255, 255, 0, 122, 255, 255,
            0, 122, 255, 255, 0, 122, 255, 255
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let message: [String: Any] = [
            "type": "frame",
            "data": (encoded as Data).base64EncodedString(),
            "metadata": ["deviceWidth": 1280, "deviceHeight": 720, "timestamp": 1_785_038_682_238]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)

        guard case .frame(let frame) = AgentBrowserMessageParser.parse(data) else {
            return XCTFail("Expected a frame message")
        }
        XCTAssertEqual(frame.sequence, -1)
        XCTAssertEqual(frame.metadata.deviceWidth, 1280)
        XCTAssertEqual(frame.image.width, 2)
    }

}
