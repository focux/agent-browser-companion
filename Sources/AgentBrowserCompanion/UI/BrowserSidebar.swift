import AppKit
import SwiftUI

struct BrowserSidebar: View {
    @EnvironmentObject private var workspace: BrowserWorkspace
    @StateObject private var hoverPreview = SidebarHoverPreviewController()

    var body: some View {
        List(selection: $workspace.selectedSessionID) {
            if !workspace.filteredSessions.isEmpty {
                ForEach(workspace.groupedFilteredSessions, id: \.hostname) { group in
                    Section(group.hostname) {
                        ForEach(group.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 6, for: .scrollContent)
        .environment(\.defaultMinListHeaderHeight, 18)
        .overlay {
            if workspace.filteredSessions.isEmpty {
                if workspace.sessions.isEmpty, workspace.isDiscoveringSessions {
                    ProgressView("Finding Browser Sessions…")
                } else {
                    ContentUnavailableView {
                        Label(workspace.sessions.isEmpty ? "No Active Browser Sessions" : "No Results", systemImage: "globe.desk")
                    } description: {
                        Text(workspace.sessions.isEmpty
                             ? "Sessions on this Mac and saved SSH hosts appear here automatically."
                             : "Try a different search.")
                    } actions: {
                        if workspace.sessions.isEmpty {
                            Button("Add SSH Host…") { workspace.isPresentingHostManager = true }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Browsers")
        .searchable(text: $workspace.searchText, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    workspace.isPresentingHostManager = true
                } label: {
                    Label("Add SSH Host", systemImage: "plus")
                }
                .labelStyle(.iconOnly)

                Menu {
                    Button("Refresh Sessions") {
                        workspace.refreshDiscoveredSessions()
                    }

                    Button("Reconnect All Sessions") {
                        workspace.reconnectAll()
                    }
                    .disabled(workspace.sessions.isEmpty)

                    Button("Manage SSH Hosts…") {
                        workspace.isPresentingHostManager = true
                    }

                    Divider()
                    Button("Clear Search") {
                        workspace.searchText = ""
                    }
                    .disabled(workspace.searchText.isEmpty)
                } label: {
                    Label("Browser List Options", systemImage: "line.3.horizontal.decrease")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
            }
        }
        .onDisappear {
            hoverPreview.dismissImmediately()
            workspace.setSidebarPreviewSession(nil)
        }
        .onAppear {
            hoverPreview.onPresentedSessionChange = { sessionID in
                workspace.setSidebarPreviewSession(sessionID)
            }
        }
    }

    private func sessionRow(_ session: BrowserSession) -> some View {
        BrowserRow(
            session: session,
            client: workspace.client(for: session),
            onHoverChanged: { isInside, anchor in
                if isInside {
                    hoverPreview.pointerEntered(
                        session: session,
                        client: workspace.client(for: session),
                        anchor: anchor
                    )
                } else {
                    hoverPreview.pointerExited(sessionID: session.id, anchor: anchor)
                }
            }
        )
        .tag(session.id)
        .contextMenu {
            Button("Reconnect") { workspace.reconnect(session) }
            if session.agentBrowserSource?.location == .ssh {
                Divider()
                Button("Forget SSH Host", role: .destructive) {
                    workspace.removeSSHHost(for: session)
                }
            }
        }
    }

}

private struct BrowserRow: View {
    let session: BrowserSession
    @ObservedObject var client: AgentBrowserStream
    let onHoverChanged: (Bool, NSView) -> Void
    private let iconSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            SiteFavicon(pageURL: client.pageURL, fallbackColor: .secondary)
                .frame(width: iconSize, height: iconSize)
                .saturation(isBrowserAvailable ? 1 : 0)
                .opacity(rowContentOpacity)

            Text(session.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .opacity(rowContentOpacity)

            Spacer(minLength: 4)

            statusIndicator
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background {
            NativeSidebarRowHover(onHoverChanged: onHoverChanged)
        }
    }

    private var isBrowserAvailable: Bool {
        client.isBrowserAvailable
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isBrowserAvailable {
            Image(systemName: "circle.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .accessibilityLabel("Live")
        } else if client.connectionState == .connecting {
            Image(systemName: "circle.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: true)
                .accessibilityLabel("Connecting")
        }
    }

    private var rowContentOpacity: Double {
        if isBrowserAvailable { return 1 }
        return client.connectionState == .connecting ? 0.7 : 0.52
    }

}
