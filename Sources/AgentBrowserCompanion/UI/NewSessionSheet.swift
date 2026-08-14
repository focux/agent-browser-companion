import SwiftUI

struct SessionEditorSheet: View {
    @EnvironmentObject private var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    let session: BrowserSession
    @State private var automaticallyConnects: Bool

    init(session: BrowserSession) {
        self.session = session
        _automaticallyConnects = State(initialValue: session.automaticallyConnects)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    LabeledContent("Website", value: session.displayTitle)
                    Toggle("Connect when the app opens", isOn: $automaticallyConnects)
                }

                Section {
                    LabeledContent("Agent Browser Session", value: session.agentBrowserSource?.sessionName ?? "Unavailable")
                    LabeledContent("Location", value: locationLabel)
                } header: {
                    Text("Managed Connection")
                } footer: {
                    Text("Connection details are managed by Agent Browser discovery so navigation, viewport control, health checks, and reconnect behavior remain available.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    workspace.updateSession(
                        session,
                        automaticallyConnects: automaticallyConnects
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 340)
        .navigationTitle("Browser Session Settings")
    }

    private var locationLabel: String {
        guard let source = session.agentBrowserSource else { return "Unavailable" }
        switch source.location {
        case .local:
            return "This Mac"
        case .ssh:
            return source.sshHost ?? "Remote over SSH"
        }
    }
}
