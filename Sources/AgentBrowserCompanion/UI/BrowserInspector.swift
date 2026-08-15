import AppKit
import SwiftUI

struct BrowserInspector: View {
    @EnvironmentObject private var workspace: BrowserWorkspace

    var body: some View {
        Group {
            if let session = workspace.selectedSession {
                InspectorContent(session: session, client: workspace.client(for: session))
                    .id(session.id)
            } else {
                ContentUnavailableView("No Browser Selected", systemImage: "sidebar.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if let session = workspace.selectedSession {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button {
                            workspace.reconnect(session)
                        } label: {
                            Label("Reconnect Stream", systemImage: "antenna.radiowaves.left.and.right")
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.endpoint, forType: .string)
                        } label: {
                            Label("Copy Endpoint", systemImage: "doc.on.doc")
                        }

                        if session.agentBrowserSource?.location == .ssh {
                            Divider()

                            Button(role: .destructive) {
                                workspace.removeSSHHost(for: session)
                            } label: {
                                Label("Forget SSH Host", systemImage: "trash")
                            }
                        }
                    } label: {
                        Label("Session Actions", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)

                    Button {
                        workspace.toggleInspector()
                    } label: {
                        Label("Hide Inspector", systemImage: "sidebar.right")
                    }
                }
            }
        }
    }
}

private struct InspectorContent: View {
    let session: BrowserSession
    @ObservedObject var client: AgentBrowserStream
    @EnvironmentObject private var workspace: BrowserWorkspace

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(session.displayTitle)
                        .lineLimit(1)
                } label: {
                    Label("Website", systemImage: "textformat")
                }
                LabeledContent {
                    Text(statusLabel)
                        .foregroundStyle(statusColor)
                } label: {
                    Label("Status", systemImage: "circle.fill")
                }
                LabeledContent {
                    Text(session.hostLabel)
                        .lineLimit(1)
                        .help(session.endpoint)
                } label: {
                    Label("Endpoint", systemImage: "network")
                }
                LabeledContent {
                    Text(latencyLabel)
                        .monospacedDigit()
                } label: {
                    Label("Stream delay", systemImage: "timer")
                }
                .help("WebSocket round-trip time, including queued preview data. This is not input response time.")
                LabeledContent {
                    Text(viewportLabel)
                        .monospacedDigit()
                } label: {
                    Label("Viewport", systemImage: "rectangle.inset.filled")
                }
            }

            if client.supportsClientStreamConfiguration {
                Section("Stream") {
                    LabeledContent {
                        Text(frameRateSummaryLabel)
                            .monospacedDigit()
                    } label: {
                        Label(
                            "Frame rate",
                            systemImage: "gauge.with.dots.needle.bottom.50percent"
                        )
                    }
                    .help("The maximum preview frame rate selected in Settings.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var viewportLabel: String {
        guard client.streamStatus.viewportWidth > 0 else { return "—" }
        return "\(client.streamStatus.viewportWidth) × \(client.streamStatus.viewportHeight)"
    }

    private var latencyLabel: String {
        guard let latency = client.roundTripLatency else { return "—" }
        let milliseconds = latency * 1_000
        return milliseconds < 1 ? "<1 ms" : "\(Int(milliseconds.rounded())) ms"
    }

    private var statusColor: Color {
        switch client.connectionState {
        case .connected:
            return client.isBrowserAvailable ? .green : .orange
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var statusLabel: String {
        client.effectiveStatusLabel
    }

    private var frameRateSummaryLabel: String {
        return workspace.preferredFPS == 0
            ? "Unlimited"
            : "Up to \(workspace.preferredFPS) fps"
    }
}
