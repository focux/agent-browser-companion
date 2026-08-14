import AppKit
import SwiftUI

/// Adds a hover treatment using the source list's own selection renderer.
///
/// SwiftUI doesn't expose a visual hover effect for macOS list rows. A sidebar
/// `List` is backed by an `NSTableView`, however, so an invisible anchor can
/// locate its `NSTableRowView` and temporarily apply that row's unemphasized
/// selection state. AppKit therefore owns the highlight's shape and metrics.
struct NativeSidebarRowHover: NSViewRepresentable {
    var onHoverChanged: ((Bool, NSView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onHoverChanged: onHoverChanged)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.coordinator = nil
    }

    final class AnchorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.attach(to: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSResponder {
        var onHoverChanged: ((Bool, NSView) -> Void)?

        private weak var anchorView: AnchorView?
        private weak var rowView: NSTableRowView?
        private weak var tableView: NSTableView?
        private var trackingArea: NSTrackingArea?
        private var notificationTokens: [NSObjectProtocol] = []
        private var isPointerInside = false
        private var isApplyingHoverSelection = false
        private var emphasisBeforeHover = false
        private var pendingInstallation = false

        init(onHoverChanged: ((Bool, NSView) -> Void)?) {
            self.onHoverChanged = onHoverChanged
            super.init()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        func attach(to anchorView: AnchorView) {
            self.anchorView = anchorView

            guard !pendingInstallation else { return }
            pendingInstallation = true

            DispatchQueue.main.async { [weak self, weak anchorView] in
                guard let self else { return }
                self.pendingInstallation = false
                guard let anchorView else {
                    self.detach()
                    return
                }
                self.installIfPossible(from: anchorView)
            }
        }

        func detach() {
            if isPointerInside, let rowView {
                onHoverChanged?(false, rowView)
            }
            restoreRowAppearance()
            notificationTokens.forEach(NotificationCenter.default.removeObserver)
            notificationTokens.removeAll()
            if let trackingArea, let rowView {
                rowView.removeTrackingArea(trackingArea)
            }
            trackingArea = nil
            rowView = nil
            tableView = nil
            isPointerInside = false
        }

        private func installIfPossible(from anchorView: AnchorView) {
            guard
                let rowView = ancestor(of: NSTableRowView.self, from: anchorView),
                let tableView = ancestor(of: NSTableView.self, from: rowView)
            else {
                return
            }

            if self.rowView === rowView,
               trackingArea != nil {
                refreshAppearance()
                return
            }

            detach()
            self.anchorView = anchorView
            self.rowView = rowView
            self.tableView = tableView

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            rowView.addTrackingArea(trackingArea)

            self.trackingArea = trackingArea
            observe(tableView: tableView, window: rowView.window)
            updatePointerLocation()
            refreshAppearance()
        }

        private func observe(tableView: NSTableView, window: NSWindow?) {
            let center = NotificationCenter.default

            notificationTokens.append(
                center.addObserver(
                    forName: NSTableView.selectionDidChangeNotification,
                    object: tableView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshAppearance()
                    }
                }
            )

            if let window {
                notificationTokens.append(
                    center.addObserver(
                        forName: NSWindow.didResignKeyNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.setPointerInside(false)
                        }
                    }
                )

                notificationTokens.append(
                    center.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.updatePointerLocation()
                            self?.refreshAppearance()
                        }
                    }
                )
            }
        }

        private func updatePointerLocation() {
            guard let rowView, let window = rowView.window, window.isKeyWindow else {
                isPointerInside = false
                return
            }

            let point = rowView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setPointerInside(rowView.bounds.contains(point))
        }

        private func setPointerInside(_ isInside: Bool) {
            guard isPointerInside != isInside else {
                refreshAppearance()
                return
            }

            isPointerInside = isInside
            if let rowView {
                onHoverChanged?(isInside, rowView)
            }
            refreshAppearance()
        }

        private func refreshAppearance() {
            guard let rowView, let tableView else { return }

            let row = tableView.row(for: rowView)
            let isActuallySelected = row >= 0 && tableView.selectedRowIndexes.contains(row)
            let shouldApplyHover = isPointerInside && !isActuallySelected

            if shouldApplyHover {
                if !isApplyingHoverSelection {
                    emphasisBeforeHover = rowView.isEmphasized
                    isApplyingHoverSelection = true
                }
                rowView.isEmphasized = false
                rowView.isSelected = true
            } else if isApplyingHoverSelection {
                isApplyingHoverSelection = false
                rowView.isSelected = isActuallySelected
                rowView.isEmphasized = isActuallySelected
                    ? (rowView.window?.isKeyWindow == true)
                    : emphasisBeforeHover
            }
        }

        private func restoreRowAppearance() {
            guard isApplyingHoverSelection, let rowView else { return }

            let row = tableView?.row(for: rowView) ?? -1
            let isActuallySelected = row >= 0 && (tableView?.selectedRowIndexes.contains(row) == true)
            rowView.isSelected = isActuallySelected
            rowView.isEmphasized = isActuallySelected
                ? (rowView.window?.isKeyWindow == true)
                : emphasisBeforeHover
            isApplyingHoverSelection = false
        }

        override func mouseEntered(with event: NSEvent) {
            setPointerInside(true)
        }

        override func mouseExited(with event: NSEvent) {
            setPointerInside(false)
        }

        private func ancestor<ViewType: NSView>(
            of type: ViewType.Type,
            from view: NSView
        ) -> ViewType? {
            var candidate = view.superview
            while let current = candidate {
                if let match = current as? ViewType {
                    return match
                }
                candidate = current.superview
            }
            return nil
        }
    }
}
