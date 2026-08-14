import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class SidebarHoverPreviewController: NSObject, ObservableObject, NSPopoverDelegate {
    private static let initialHoverDelay = Duration.milliseconds(650)
    private static let dismissalDelay = Duration.milliseconds(240)

    private let model = SidebarHoverPreviewModel()
    private let popover = NSPopover()
    private var presentationTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private weak var hoveredAnchor: NSView?
    private var hoveredSessionID: BrowserSession.ID?
    private var isPointerInsidePopover = false
    private var positioningAnchorView: PopoverPositioningAnchorView?
    private var presentedSessionID: BrowserSession.ID?
    var onPresentedSessionChange: ((BrowserSession.ID?) -> Void)?

    override init() {
        super.init()

        let rootView = SidebarHoverPreview(model: model) { [weak self] isInside in
            self?.popoverHoverChanged(isInside)
        }
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(width: 332, height: 238)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func pointerEntered(
        session: BrowserSession,
        client: AgentBrowserStream,
        anchor: NSView
    ) {
        dismissalTask?.cancel()
        hoveredSessionID = session.id
        hoveredAnchor = anchor

        if popover.isShown {
            present(session: session, client: client)
            movePopover(to: anchor)
            return
        }

        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self, weak anchor] in
            try? await Task.sleep(for: Self.initialHoverDelay)
            guard !Task.isCancelled,
                  let self,
                  let anchor,
                  self.hoveredSessionID == session.id,
                  self.hoveredAnchor === anchor,
                  let positioningAnchor = self.positioningAnchor(for: anchor) else { return }

            self.present(session: session, client: client)
            self.popover.show(
                relativeTo: positioningAnchor.bounds,
                of: positioningAnchor,
                preferredEdge: .maxX
            )
        }
    }

    func pointerExited(sessionID: BrowserSession.ID, anchor: NSView) {
        guard hoveredSessionID == sessionID, hoveredAnchor === anchor else { return }
        presentationTask?.cancel()
        hoveredSessionID = nil
        hoveredAnchor = nil
        scheduleDismissal()
    }

    func dismissImmediately() {
        presentationTask?.cancel()
        dismissalTask?.cancel()
        hoveredSessionID = nil
        hoveredAnchor = nil
        isPointerInsidePopover = false
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        model.clear()
        presentedSessionID = nil
        onPresentedSessionChange?(nil)
        positioningAnchorView?.removeFromSuperview()
        positioningAnchorView = nil
    }

    private func present(session: BrowserSession, client: AgentBrowserStream) {
        model.present(session: session, client: client)
        guard presentedSessionID != session.id else { return }
        presentedSessionID = session.id
        onPresentedSessionChange?(session.id)
    }

    private func popoverHoverChanged(_ isInside: Bool) {
        isPointerInsidePopover = isInside
        if isInside {
            dismissalTask?.cancel()
        } else if hoveredSessionID == nil {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dismissalDelay)
            guard !Task.isCancelled,
                  let self,
                  self.hoveredSessionID == nil,
                  !self.isPointerInsidePopover else { return }
            self.popover.performClose(nil)
        }
    }

    private func movePopover(to anchor: NSView) {
        guard let positioningAnchor = positioningAnchorView,
              let container = positioningAnchor.superview,
              anchor.window === container.window else { return }

        let targetFrame = anchor.convert(anchor.bounds, to: container)
        guard targetFrame != positioningAnchor.frame else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            positioningAnchor.frame = targetFrame
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2,
                0.8,
                0.2,
                1
            )
            positioningAnchor.animator().frame = targetFrame
        }
    }

    private func positioningAnchor(for row: NSView) -> PopoverPositioningAnchorView? {
        guard let container = row.window?.contentView else { return nil }

        if let positioningAnchorView,
           positioningAnchorView.superview === container {
            positioningAnchorView.frame = row.convert(row.bounds, to: container)
            return positioningAnchorView
        }

        positioningAnchorView?.removeFromSuperview()
        let positioningAnchor = PopoverPositioningAnchorView(
            frame: row.convert(row.bounds, to: container)
        )
        container.addSubview(positioningAnchor, positioned: .above, relativeTo: nil)
        positioningAnchorView = positioningAnchor
        return positioningAnchor
    }
}

private final class PopoverPositioningAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class SidebarHoverPreviewModel: ObservableObject {
    struct Payload {
        let session: BrowserSession
        let client: AgentBrowserStream
    }

    @Published private(set) var payload: Payload?

    func present(session: BrowserSession, client: AgentBrowserStream) {
        payload = Payload(session: session, client: client)
    }

    func clear() {
        payload = nil
    }
}

private struct SidebarHoverPreview: View {
    @ObservedObject var model: SidebarHoverPreviewModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            if let payload = model.payload {
                SidebarHoverPreviewContent(
                    session: payload.session,
                    client: payload.client
                )
            }
        }
        .frame(width: 332, height: 238)
        .onHover(perform: onHoverChanged)
    }
}

private struct SidebarHoverPreviewContent: View {
    let session: BrowserSession
    @ObservedObject var client: AgentBrowserStream

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)

                if client.currentFrame != nil {
                    MetalBrowserSurface(stream: client, contentMode: .fit)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: client.connectionState == .connecting
                              ? "arrow.trianglehead.2.clockwise.rotate.90"
                              : "rectangle.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(client.effectiveStatusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 9) {
                SiteFavicon(pageURL: pageURL, fallbackColor: .secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)

                    Text(pageURL?.absoluteString ?? "Page URL unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(11)
    }

    private var pageURL: URL? {
        client.pageURL ?? session.activePageURL
    }
}
