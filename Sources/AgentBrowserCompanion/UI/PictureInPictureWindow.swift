import AppKit
import SwiftUI

private final class PictureInPicturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PictureInPictureWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(workspace: BrowserWorkspace, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let panel = PictureInPicturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 202.5),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent Browser Picture in Picture"
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 157.5)
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentViewController = NSHostingController(
            rootView: PictureInPictureView().environmentObject(workspace)
        )
        panel.setContentSize(NSSize(width: 360, height: 202.5))

        super.init(window: panel)
        panel.delegate = self
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct PictureInPictureView: View {
    @EnvironmentObject private var workspace: BrowserWorkspace
    @State private var hoveredSessionID: BrowserSession.ID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear

                ForEach(Array(workspace.pictureInPictureSessions.enumerated()), id: \.element.id) { index, session in
                    let placement = PictureInPictureStackLayout.placement(
                        index: index,
                        count: workspace.pictureInPictureSessions.count,
                        in: proxy.size
                    )
                    PictureInPictureCard(
                        session: session,
                        client: workspace.client(for: session),
                        isFront: placement.isFront,
                        isHovered: hoveredSessionID == session.id,
                        onExit: { workspace.removeFromPictureInPicture(session.id) }
                    )
                    .frame(width: placement.frame.width, height: placement.frame.height)
                    .position(x: placement.frame.midX, y: placement.frame.midY)
                    .zIndex(placement.zIndex)
                    .opacity(
                        placement.isFront || hoveredSessionID == session.id
                            ? 1
                            : max(0.46, 1 - Double(placement.depth) * 0.22)
                    )
                    .overlay {
                        if !placement.isFront {
                            Button {
                                hoveredSessionID = nil
                                workspace.bringPictureInPictureSessionToFront(session.id)
                            } label: {
                                Rectangle()
                                    .fill(.black.opacity(0.001))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Bring \(session.displayTitle) to Front")
                            .help("Bring \(session.displayTitle) to Front")
                        }
                    }
                    .onHover { isHovering in
                        if isHovering {
                            hoveredSessionID = session.id
                        } else if hoveredSessionID == session.id {
                            hoveredSessionID = nil
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: workspace.pictureInPictureSessionIDs)
        .animation(.easeOut(duration: 0.14), value: hoveredSessionID)
    }
}

struct PictureInPictureStackLayout {
    struct Placement {
        let frame: CGRect
        let zIndex: Double
        let isFront: Bool
        let depth: Int
    }

    static func placement(index: Int, count: Int, in size: CGSize) -> Placement {
        let safeCount = max(count, 1)
        let clampedIndex = min(max(index, 0), safeCount - 1)
        let depth = safeCount - clampedIndex - 1
        let maximumDepth = min(safeCount - 1, 3)
        let visibleDepth = min(depth, maximumDepth)
        let outerInset: CGFloat = maximumDepth == 0 ? 0 : 8
        let horizontalStep: CGFloat = 14
        let verticalStep: CGFloat = 10
        let width = max(1, size.width - outerInset * 2 - horizontalStep * CGFloat(maximumDepth))
        let height = max(1, size.height - outerInset * 2 - verticalStep * CGFloat(maximumDepth))
        let origin = CGPoint(
            x: outerInset + horizontalStep * CGFloat(visibleDepth),
            y: outerInset + verticalStep * CGFloat(maximumDepth - visibleDepth)
        )

        return Placement(
            frame: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            zIndex: Double(clampedIndex),
            isFront: depth == 0,
            depth: depth
        )
    }
}

enum PictureInPictureFrameAppearance {
    static func bottomBandLuminance(of image: CGImage) -> Double? {
        let bandHeight = max(1, image.height / 3)
        let bandRect = CGRect(
            x: 0,
            y: image.height - bandHeight,
            width: image.width,
            height: bandHeight
        )
        guard let band = image.cropping(to: bandRect) else { return nil }

        let width = 24
        let height = 8
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        return pixels.withUnsafeMutableBytes { bytes -> Double? in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }

            context.interpolationQuality = .low
            context.draw(band, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixelBytes = bytes.bindMemory(to: UInt8.self)
            var luminance = 0.0
            for offset in stride(from: 0, to: pixelBytes.count, by: bytesPerPixel) {
                let red = Double(pixelBytes[offset]) / 255
                let green = Double(pixelBytes[offset + 1]) / 255
                let blue = Double(pixelBytes[offset + 2]) / 255
                luminance += red * 0.2126 + green * 0.7152 + blue * 0.0722
            }
            return luminance / Double(width * height)
        }
    }

    static func prefersDarkForeground(luminance: Double, currentlyDark: Bool) -> Bool {
        currentlyDark ? luminance >= 0.46 : luminance > 0.62
    }
}

private struct PictureInPictureCard: View {
    let session: BrowserSession
    @ObservedObject var client: AgentBrowserStream
    let isFront: Bool
    let isHovered: Bool
    let onExit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var usesDarkTitle = false

    var body: some View {
        ZStack {
            Color.black

            if client.currentFrame != nil {
                MetalBrowserSurface(stream: client, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(isFront)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "pip")
                        .font(.system(size: 34, weight: .light))
                    Text(client.connectionState == .connecting ? "Connecting…" : "Waiting for \(session.displayTitle)")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.72))
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(client.streamStatus.screencasting ? .green : .yellow)
                    .frame(width: 6, height: 6)
                Text(session.displayTitle)
                    .lineLimit(1)
                Spacer()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(titleColor)
            .padding(.horizontal, 11)
            .padding(.top, 28)
            .padding(.bottom, 9)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(adaptiveTint)
                }
                .mask {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.78), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .opacity(isHovered ? 1 : 0)
            .offset(y: reduceMotion || isHovered ? 0 : 4)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if isFront {
                exitButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: isHovered)
        .task(id: appearanceSampleID) {
            guard let image = client.currentFrame?.image,
                  let luminance = PictureInPictureFrameAppearance.bottomBandLuminance(of: image) else {
                return
            }
            let nextValue = PictureInPictureFrameAppearance.prefersDarkForeground(
                luminance: luminance,
                currentlyDark: usesDarkTitle
            )
            guard nextValue != usesDarkTitle else { return }
            if reduceMotion {
                usesDarkTitle = nextValue
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    usesDarkTitle = nextValue
                }
            }
        }
    }

    private var appearanceSampleID: Int {
        max(client.currentFrame?.sequence ?? 0, 0) / 15
    }

    private var titleColor: Color {
        usesDarkTitle ? .black.opacity(0.82) : .white.opacity(0.92)
    }

    private var adaptiveTint: Color {
        usesDarkTitle ? .white.opacity(0.12) : .black.opacity(0.18)
    }

    @ViewBuilder
    private var exitButton: some View {
        if #available(macOS 26.0, *) {
            exitButtonLabel
                .buttonStyle(.glass)
        } else {
            exitButtonLabel
                .buttonStyle(.bordered)
        }
    }

    private var exitButtonLabel: some View {
        Button("Return to Main Window", systemImage: "pip.exit", action: onExit)
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .semibold))
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Return to Main Window")
    }
}
