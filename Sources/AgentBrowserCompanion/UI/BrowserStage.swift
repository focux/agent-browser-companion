import SwiftUI

struct BrowserStage: View {
    @EnvironmentObject private var workspace: BrowserWorkspace

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let session = workspace.selectedSession {
                    ConnectedBrowserStage(
                        session: session,
                        client: workspace.client(for: session),
                        isPresentedInPictureInPicture: workspace.isSelectedSessionInPictureInPicture,
                        returnToMainWindow: workspace.togglePictureInPicture
                    )
                        .id(session.id)
                        .task(id: workspace.client(for: session).pageURL) {
                            await workspace.refreshSelectedNavigationCapabilities()
                        }
                } else {
                    SelectionPlaceholder(hasSessions: !workspace.sessions.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                workspace.updateBrowserStageSize(geometry.size)
            }
            .onChange(of: geometry.size) { _, size in
                workspace.updateBrowserStageSize(size)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("")
        .toolbar {
            if let client = workspace.selectedClient {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        workspace.runNavigationCommand(.back)
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(
                        !workspace.canNavigateSelectedSession
                            || !workspace.canGoBack
                            || workspace.isRunningNavigationCommand
                    )

                    Button {
                        workspace.runNavigationCommand(.forward)
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(
                        !workspace.canNavigateSelectedSession
                            || !workspace.canGoForward
                            || workspace.isRunningNavigationCommand
                    )
                }

                ToolbarItem(placement: .principal) {
                    if let pageURL = client.pageURL {
                        HStack(spacing: 7) {
                            SiteFavicon(pageURL: pageURL)
                                .frame(width: 16, height: 16)
                            Text(pageURL.absoluteString)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 373)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .help(pageURL.absoluteString)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        workspace.runNavigationCommand(.reload)
                    } label: {
                        Label("Reload Browser", systemImage: "arrow.clockwise")
                    }
                    .disabled(!workspace.canNavigateSelectedSession || workspace.isRunningNavigationCommand)
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        workspace.togglePictureInPicture()
                    } label: {
                        Label(
                            workspace.isSelectedSessionInPictureInPicture ? "Return to Main Window" : "Add to Picture in Picture",
                            systemImage: workspace.isSelectedSessionInPictureInPicture ? "pip.swap" : "pip.enter"
                        )
                    }
                }
            }
        }
    }
}

private struct ConnectedBrowserStage: View {
    let session: BrowserSession
    @ObservedObject var client: AgentBrowserStream
    let isPresentedInPictureInPicture: Bool
    let returnToMainWindow: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            if isPresentedInPictureInPicture {
                PictureInPictureHandoff(returnToMainWindow: returnToMainWindow)
            } else if client.currentFrame != nil {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)

                    // Keep the previous frame at its real aspect ratio while
                    // the remote viewport catches up. Once settled, the
                    // viewport ratio matches this center pane edge to edge.
                    MetalBrowserSurface(stream: client, contentMode: .fill)
                        .aspectRatio(viewportAspectRatio, contentMode: .fit)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .saturation(client.isBrowserAvailable ? 1 : 0)
                    .opacity(client.isBrowserAvailable ? 1 : 0.58)
                    .allowsHitTesting(client.isBrowserAvailable)
                    .overlay(alignment: .bottom) {
                        if !client.isBrowserAvailable {
                            Label(client.effectiveStatusLabel, systemImage: "pause.circle.fill")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 24)
                        }
                    }
            } else {
                ConnectionPlaceholder(session: session, client: client)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser session \(session.displayTitle)")
    }

    private var viewportAspectRatio: CGFloat {
        let width = client.currentFrame?.image.width ?? client.streamStatus.viewportWidth
        let height = client.currentFrame?.image.height ?? client.streamStatus.viewportHeight
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return CGFloat(width) / CGFloat(height)
    }
}

private struct PictureInPictureHandoff: View {
    let returnToMainWindow: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Playing in Picture in Picture", systemImage: "pip")
        } description: {
            Text("The live browser is being shown in the Picture in Picture window.")
        } actions: {
            Button("Return to Main Window", systemImage: "pip.exit", action: returnToMainWindow)
                .buttonStyle(.borderedProminent)
        }
    }
}

enum BrowserViewportSizing {
    static func viewport(
        for containerSize: CGSize,
        minimumWidth: Int,
        minimumHeight: Int,
        inset: CGFloat = 0,
        maximumWidth: Int = 2_560,
        maximumHeight: Int = 1_600
    ) -> BrowserViewportSize? {
        let availableWidth = containerSize.width - inset * 2
        let availableHeight = containerSize.height - inset * 2
        guard availableWidth >= 320,
              availableHeight >= 240,
              minimumWidth > 0,
              minimumHeight > 0,
              maximumWidth >= minimumWidth,
              maximumHeight >= minimumHeight else { return nil }

        let containerAspectRatio = availableWidth / availableHeight
        let heightRequiredByWidth = CGFloat(minimumWidth) / containerAspectRatio
        let idealHeight = max(CGFloat(minimumHeight), heightRequiredByWidth)
        let idealWidth = idealHeight * containerAspectRatio

        if idealWidth <= CGFloat(maximumWidth), idealHeight <= CGFloat(maximumHeight) {
            return BrowserViewportSize(
                width: max(minimumWidth, Int(idealWidth.rounded(.down))),
                height: max(minimumHeight, Int(idealHeight.rounded(.down)))
            )
        }

        // Extremely wide or tall panes cannot match the pane ratio without an
        // unnecessarily large stream. Preserve the minimum viewport and cap the
        // expanding axis; the card will retain a small amount of outer padding.
        if idealWidth > CGFloat(maximumWidth) {
            let cappedHeight = max(
                minimumHeight,
                Int((CGFloat(maximumWidth) / containerAspectRatio).rounded(.down))
            )
            return BrowserViewportSize(width: maximumWidth, height: cappedHeight)
        }

        return BrowserViewportSize(
            width: max(
                minimumWidth,
                Int((CGFloat(maximumHeight) * containerAspectRatio).rounded(.down))
            ),
            height: maximumHeight
        )
    }
}

private struct ConnectionPlaceholder: View {
    let session: BrowserSession
    @ObservedObject var client: AgentBrowserStream
    @EnvironmentObject private var workspace: BrowserWorkspace

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 124, height: 92)
                Image(systemName: client.connectionState == .connecting ? "antenna.radiowaves.left.and.right" : "globe.desk")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: client.connectionState == .connecting)
            }

            VStack(spacing: 5) {
                Text(session.displayTitle)
                    .font(.title2.weight(.semibold))
                Text(placeholderText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if client.connectionState != .connecting {
                Button("Connect") {
                    workspace.connectStream(for: session)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
    }

    private var placeholderText: String {
        switch client.connectionState {
        case .disconnected:
            "Connect to the Agent Browser stream to view and control it."
        case .connecting:
            "Connecting securely to \(session.hostLabel)…"
        case .connected:
            "Connected. Waiting for the first viewport frame."
        case .failed(let message):
            message
        }
    }
}

private struct SelectionPlaceholder: View {
    let hasSessions: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a Browser Session")
                .font(.title3.weight(.semibold))
            Text(hasSessions
                 ? "Choose a session in the sidebar to view and control its browser."
                 : "Active sessions on this Mac and saved SSH hosts will appear here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
    }
}
