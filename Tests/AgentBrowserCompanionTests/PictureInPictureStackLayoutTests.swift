import CoreGraphics
import XCTest
@testable import AgentBrowserCompanion

final class PictureInPictureStackLayoutTests: XCTestCase {
    func testRearCardKeepsAVisibleAndClickableEdge() {
        let size = CGSize(width: 320, height: 200)
        let rear = PictureInPictureStackLayout.placement(index: 0, count: 2, in: size)
        let front = PictureInPictureStackLayout.placement(index: 1, count: 2, in: size)

        XCTAssertLessThan(rear.frame.minY, front.frame.minY)
        XCTAssertGreaterThan(rear.frame.maxX, front.frame.maxX)
        XCTAssertLessThan(rear.zIndex, front.zIndex)
        XCTAssertFalse(rear.isFront)
        XCTAssertTrue(front.isFront)
    }

    func testVisibleCardsStayInsideThePanel() {
        let size = CGSize(width: 320, height: 200)
        let panelBounds = CGRect(origin: .zero, size: size)

        for index in 0..<4 {
            let placement = PictureInPictureStackLayout.placement(index: index, count: 4, in: size)
            XCTAssertTrue(panelBounds.contains(placement.frame))
        }
    }

    func testFrameAppearanceMeasuresDarkAndLightFrames() throws {
        let dark = try XCTUnwrap(solidImage(red: 0, green: 0, blue: 0))
        let light = try XCTUnwrap(solidImage(red: 1, green: 1, blue: 1))

        XCTAssertLessThan(try XCTUnwrap(PictureInPictureFrameAppearance.bottomBandLuminance(of: dark)), 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(PictureInPictureFrameAppearance.bottomBandLuminance(of: light)), 0.98)
    }

    func testFrameAppearanceUsesHysteresisNearMidGray() {
        XCTAssertTrue(PictureInPictureFrameAppearance.prefersDarkForeground(
            luminance: 0.7,
            currentlyDark: false
        ))
        XCTAssertTrue(PictureInPictureFrameAppearance.prefersDarkForeground(
            luminance: 0.5,
            currentlyDark: true
        ))
        XCTAssertFalse(PictureInPictureFrameAppearance.prefersDarkForeground(
            luminance: 0.4,
            currentlyDark: true
        ))
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return context.makeImage()
    }
}
