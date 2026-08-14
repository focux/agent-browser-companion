import CoreGraphics
import XCTest
@testable import AgentBrowserCompanion

@MainActor
final class MetalBrowserSurfaceTests: XCTestCase {
    func testAcceptsAnEqualFrameSequenceWhenTheBrowserSourceChanges() throws {
        let image = try XCTUnwrap(solidImage())
        let frame = BrowserFrame(sequence: 42, image: image, metadata: StreamMetadata())
        let view = BrowserMetalView()
        let firstSource = UUID()
        let secondSource = UUID()

        XCTAssertTrue(view.present(frame, sourceID: firstSource))
        XCTAssertFalse(view.present(frame, sourceID: firstSource))
        XCTAssertTrue(view.present(frame, sourceID: secondSource))
    }

    private func solidImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }
}
