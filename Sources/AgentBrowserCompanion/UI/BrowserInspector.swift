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
                            workspace.edit(session)
                        } label: {
                            Label("Session Settings…", systemImage: "gearshape")
                        }

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

                        Divider()

                        Button(role: .destructive) {
                            workspace.remove(session)
                        } label: {
                            Label("Remove Browser Session", systemImage: "trash")
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
                    Label("Latency", systemImage: "timer")
                }
                .help("WebSocket round-trip time to the Agent Browser stream.")
                LabeledContent {
                    Text(viewportLabel)
                        .monospacedDigit()
                } label: {
                    Label("Viewport", systemImage: "rectangle.inset.filled")
                }
            }

            Section("Stream") {
                if client.supportsClientStreamConfiguration {
                    LabeledContent {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { Double(workspace.preferredFPS) },
                                    set: { workspace.preferredFPS = Int($0.rounded()) }
                                ),
                                in: 0...120,
                                step: 1
                            )
                            Text(maximumRateLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    } label: {
                        Label("Maximum FPS", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    Picker("Delivery", selection: $workspace.pacing) {
                        ForEach(StreamPacing.allCases) { pacing in
                            Text(pacing.label).tag(pacing)
                        }
                    }
                }
                if let age = client.frameAge {
                    LabeledContent("Frame age", value: formatFrameAge(age))
                }
                if client.currentFrame != nil, client.isBrowserAvailable {
                    LabeledContent("Observed", value: observedRateLabel)
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

    private func formatFrameAge(_ age: TimeInterval) -> String {
        return age < 1 ? "\(Int(age * 1_000)) ms" : String(format: "%.1f s", age)
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

    private var maximumRateLabel: String {
        workspace.preferredFPS == 0 ? "Unlimited" : "\(workspace.preferredFPS) fps"
    }

    private var observedRateLabel: String {
        client.framesPerSecond < 1 ? "Idle" : "\(Int(client.framesPerSecond)) fps"
    }
}
