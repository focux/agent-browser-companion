import CoreImage
import MetalKit
import SwiftUI

enum BrowserSurfaceContentMode {
    case fit
    case fill
}

struct MetalBrowserSurface: NSViewRepresentable {
    @ObservedObject var stream: AgentBrowserStream
    var contentMode: BrowserSurfaceContentMode = .fit

    func makeNSView(context: Context) -> BrowserMetalView {
        let view = BrowserMetalView()
        view.contentMode = contentMode
        configureInput(on: view)
        return view
    }

    func updateNSView(_ view: BrowserMetalView, context: Context) {
        view.contentMode = contentMode
        configureInput(on: view)
        guard let frame = stream.currentFrame else { return }
        view.present(frame, sourceID: stream.id)
    }

    private func configureInput(on view: BrowserMetalView) {
        view.onMouse = { [weak stream] event in
            stream?.sendMouse(
                type: event.type,
                point: event.point,
                button: event.button,
                clickCount: event.clickCount,
                deltaX: event.deltaX,
                deltaY: event.deltaY,
                modifiers: event.modifiers
            )
        }
        view.onKey = { [weak stream] event in
            if event.type == "char", let text = event.text {
                stream?.sendCharacter(text)
            } else {
                stream?.sendKey(
                    type: event.type,
                    key: event.key ?? "",
                    code: event.code ?? "",
                    text: event.text,
                    modifiers: event.modifiers
                )
            }
        }
        view.onTouch = { [weak stream] event in
            stream?.sendTouch(type: event.type, points: event.points)
        }
    }
}

private struct RemoteMouseEvent {
    let type: String
    let point: CGPoint
    var button: String?
    var clickCount: Int?
    var deltaX: Double?
    var deltaY: Double?
    var modifiers: Int
}

private struct RemoteKeyEvent {
    let type: String
    var key: String?
    var code: String?
    var text: String?
    var modifiers: Int
}

private struct RemoteTouchEvent {
    let type: String
    let points: [RemoteTouchPoint]
}

final class BrowserMetalView: MTKView, MTKViewDelegate {
    fileprivate var onMouse: ((RemoteMouseEvent) -> Void)?
    fileprivate var onKey: ((RemoteKeyEvent) -> Void)?
    fileprivate var onTouch: ((RemoteTouchEvent) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let imageContext: CIContext
    private var browserFrame: BrowserFrame?
    private var presentedSourceID: BrowserSession.ID?
    private var queuedSequence = -1
    private var renderedSequence = -1
    private var trackingArea: NSTrackingArea?
    private var pinchCenter: CGPoint?
    private var pinchDistance: CGFloat = 0
    var contentMode: BrowserSurfaceContentMode = .fit {
        didSet {
            guard oldValue != contentMode else { return }
            renderedSequence = -1
            setNeedsDisplay(bounds)
        }
    }

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Agent Browser Companion requires a Metal-capable Mac.")
        }
        self.commandQueue = commandQueue
        imageContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .priorityRequestLow: false
        ])
        super.init(frame: .zero, device: device)
        delegate = self
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0.055, 0.06, 0.07, 1)
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityLabel("Remote browser viewport")
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    @discardableResult
    func present(_ frame: BrowserFrame, sourceID: BrowserSession.ID) -> Bool {
        if presentedSourceID != sourceID {
            presentedSourceID = sourceID
            queuedSequence = -1
            renderedSequence = -1
        }
        guard frame.sequence != queuedSequence,
              frame.sequence != renderedSequence else { return false }
        browserFrame = frame
        queuedSequence = frame.sequence
        setNeedsDisplay(bounds)
        return true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setNeedsDisplay(bounds)
    }

    func draw(in view: MTKView) {
        guard let frame = browserFrame,
              frame.sequence != renderedSequence,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let target = CGRect(origin: .zero, size: drawableSize)
        let source = CIImage(cgImage: frame.image)
        let scale: CGFloat
        switch contentMode {
        case .fit:
            scale = min(target.width / source.extent.width, target.height / source.extent.height)
        case .fill:
            scale = max(target.width / source.extent.width, target.height / source.extent.height)
        }
        let width = source.extent.width * scale
        let height = source.extent.height * scale
        let transform = CGAffineTransform(
            translationX: (target.width - width) / 2,
            y: (target.height - height) / 2
        ).scaledBy(x: scale, y: scale)
        let background = CIImage(color: CIColor(red: 0.055, green: 0.06, blue: 0.07)).cropped(to: target)
        let composition = source.transformed(by: transform).composited(over: background)

        imageContext.render(
            composition,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: colorspace ?? CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderedSequence = frame.sequence
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event, type: "mousePressed", button: "left", clickCount: event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "left", clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "left")
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event, type: "mousePressed", button: "right", clickCount: event.clickCount)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "right", clickCount: event.clickCount)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "right")
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouse(event, type: "mousePressed", button: "middle", clickCount: event.clickCount)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "middle", clickCount: event.clickCount)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved")
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(for: event) else { return }
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        onMouse?(RemoteMouseEvent(
            type: "mouseWheel",
            point: point,
            deltaX: -event.scrollingDeltaX * multiplier,
            deltaY: -event.scrollingDeltaY * multiplier,
            modifiers: event.modifierFlags.agentBrowserMask
        ))
    }

    override func magnify(with event: NSEvent) {
        if event.phase.contains(.began) {
            guard let center = remotePoint(for: event),
                  let viewportSize = remoteViewportSize else { return }
            window?.makeFirstResponder(self)
            pinchCenter = center
            pinchDistance = max(24, min(viewportSize.width, viewportSize.height) * 0.12)
            sendPinch(type: "touchStart")
            return
        }

        if event.phase.contains(.changed) {
            guard pinchCenter != nil else { return }
            pinchDistance *= min(max(1 + event.magnification, 0.5), 1.5)
            sendPinch(type: "touchMove")
            return
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            guard pinchCenter != nil else { return }
            onTouch?(RemoteTouchEvent(type: "touchEnd", points: []))
            pinchCenter = nil
            pinchDistance = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        let mapped = KeyMapper.map(event)
        if mapped.isTextInput, let text = event.characters, !text.isEmpty {
            onKey?(RemoteKeyEvent(type: "char", text: text, modifiers: event.modifierFlags.agentBrowserMask))
        } else {
            onKey?(RemoteKeyEvent(
                type: "keyDown",
                key: mapped.key,
                code: mapped.code,
                modifiers: event.modifierFlags.agentBrowserMask
            ))
        }
    }

    override func keyUp(with event: NSEvent) {
        let mapped = KeyMapper.map(event)
        guard !mapped.isTextInput else { return }
        onKey?(RemoteKeyEvent(
            type: "keyUp",
            key: mapped.key,
            code: mapped.code,
            modifiers: event.modifierFlags.agentBrowserMask
        ))
    }

    private func sendMouse(_ event: NSEvent, type: String, button: String? = nil, clickCount: Int? = nil) {
        guard let point = remotePoint(for: event) else { return }
        onMouse?(RemoteMouseEvent(
            type: type,
            point: point,
            button: button,
            clickCount: clickCount,
            modifiers: event.modifierFlags.agentBrowserMask
        ))
    }

    private func remotePoint(for event: NSEvent) -> CGPoint? {
        guard let frame = browserFrame else { return nil }
        let imageWidth = CGFloat(frame.image.width)
        let imageHeight = CGFloat(frame.image.height)
        let imageRatio = imageWidth / imageHeight
        let metadataWidth = CGFloat(frame.metadata.deviceWidth)
        let metadataHeight = CGFloat(frame.metadata.deviceHeight)
        let metadataRatio = metadataHeight > 0 ? metadataWidth / metadataHeight : imageRatio
        let metadataMatchesFrame = abs(imageRatio - metadataRatio) < 0.02
        let viewportWidth = metadataMatchesFrame && metadataWidth > 0 ? metadataWidth : imageWidth
        let viewportHeight = metadataMatchesFrame && metadataHeight > 0 ? metadataHeight : imageHeight
        let scale: CGFloat
        switch contentMode {
        case .fit:
            scale = min(bounds.width / imageWidth, bounds.height / imageHeight)
        case .fill:
            scale = max(bounds.width / imageWidth, bounds.height / imageHeight)
        }
        let contentSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let contentRect = CGRect(
            x: (bounds.width - contentSize.width) / 2,
            y: (bounds.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        let local = convert(event.locationInWindow, from: nil)
        guard contentMode == .fill || contentRect.contains(local) else { return nil }
        let x = (local.x - contentRect.minX) / contentRect.width * viewportWidth
        let y = (contentRect.maxY - local.y) / contentRect.height * viewportHeight
        return CGPoint(x: x, y: y)
    }

    private var remoteViewportSize: CGSize? {
        guard let frame = browserFrame else { return nil }
        let imageSize = CGSize(width: CGFloat(frame.image.width), height: CGFloat(frame.image.height))
        let metadataSize = CGSize(
            width: CGFloat(frame.metadata.deviceWidth),
            height: CGFloat(frame.metadata.deviceHeight)
        )
        guard metadataSize.width > 0, metadataSize.height > 0 else { return imageSize }
        let imageRatio = imageSize.width / imageSize.height
        let metadataRatio = metadataSize.width / metadataSize.height
        return abs(imageRatio - metadataRatio) < 0.02 ? metadataSize : imageSize
    }

    private func sendPinch(type: String) {
        guard let center = pinchCenter, let viewportSize = remoteViewportSize else { return }
        let halfDistance = pinchDistance / 2
        let leftX = min(max(center.x - halfDistance, 0), viewportSize.width)
        let rightX = min(max(center.x + halfDistance, 0), viewportSize.width)
        let y = min(max(center.y, 0), viewportSize.height)
        onTouch?(RemoteTouchEvent(type: type, points: [
            RemoteTouchPoint(x: leftX, y: y, id: 0),
            RemoteTouchPoint(x: rightX, y: y, id: 1)
        ]))
    }
}

private extension NSEvent.ModifierFlags {
    var agentBrowserMask: Int {
        var value = 0
        if contains(.option) { value |= 1 }
        if contains(.control) { value |= 2 }
        if contains(.command) { value |= 4 }
        if contains(.shift) { value |= 8 }
        return value
    }
}

private enum KeyMapper {
    struct Mapping {
        let key: String
        let code: String
        let isTextInput: Bool
    }

    static func map(_ event: NSEvent) -> Mapping {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if let special = specialKeys[event.keyCode] {
            return Mapping(key: special.0, code: special.1, isTextInput: false)
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        let key = characters.lowercased()
        let code: String
        if key.count == 1, let character = key.first {
            if character.isLetter { code = "Key\(String(character).uppercased())" }
            else if character.isNumber { code = "Digit\(character)" }
            else { code = key }
        } else {
            code = key
        }
        return Mapping(key: key, code: code, isTextInput: modifiers.isEmpty)
    }

    private static let specialKeys: [UInt16: (String, String)] = [
        36: ("Enter", "Enter"),
        48: ("Tab", "Tab"),
        51: ("Backspace", "Backspace"),
        53: ("Escape", "Escape"),
        117: ("Delete", "Delete"),
        115: ("Home", "Home"),
        119: ("End", "End"),
        116: ("PageUp", "PageUp"),
        121: ("PageDown", "PageDown"),
        123: ("ArrowLeft", "ArrowLeft"),
        124: ("ArrowRight", "ArrowRight"),
        125: ("ArrowDown", "ArrowDown"),
        126: ("ArrowUp", "ArrowUp")
    ]
}
