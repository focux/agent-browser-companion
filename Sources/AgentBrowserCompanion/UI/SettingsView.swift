import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var workspace: BrowserWorkspace

    var body: some View {
        Form {
            Section("Streaming") {
                Picker("Default frame rate", selection: $workspace.preferredFPS) {
                    Text("Unlimited").tag(0)
                    ForEach([10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { fps in
                        Text("Up to \(fps) fps").tag(fps)
                    }
                }
                Picker("Frame delivery", selection: $workspace.pacing) {
                    ForEach(StreamPacing.allCases) { pacing in
                        Text(pacing.label).tag(pacing)
                    }
                }
            }

            Section {
                Text("Acknowledgement delivery keeps at most one frame in flight and skips stale preview frames on remote links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 250)
    }
}
