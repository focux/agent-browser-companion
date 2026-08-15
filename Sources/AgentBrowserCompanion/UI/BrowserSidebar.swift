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
                ContentUnavailableView {
                    Label(workspace.sessions.isEmpty ? "No Browser Sessions" : "No Results", systemImage: "globe.desk")
                } description: {
                    Text(workspace.sessions.isEmpty ? "Discover an active Agent Browser session to watch and control it." : "Try a different search.")
                } actions: {
                    if workspace.sessions.isEmpty {
                        Button("Discover Sessions…") { workspace.isPresentingSessionDiscovery = true }
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
                    workspace.isPresentingSessionDiscovery = true
                } label: {
                    Label("Discover Browser Sessions", systemImage: "plus")
                }
                .labelStyle(.iconOnly)

                Menu {
                    Button("Reconnect All Sessions") {
                        workspace.reconnectAll()
                    }
                    .disabled(workspace.sessions.isEmpty)

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
            Button("Session Settings…") { workspace.edit(session) }
            Button("Reconnect") { workspace.reconnect(session) }
            Divider()
            Button("Remove", role: .destructive) { workspace.remove(session) }
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
