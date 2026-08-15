import SwiftUI

struct HostManagementSheet: View {
    @EnvironmentObject private var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var sshHost = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add Host")
                    .font(.title2.weight(.semibold))
                Text("Sessions on this Mac appear automatically. Add another machine to monitor it over SSH.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form {
                Section {
                    TextField(
                        "SSH Host",
                        text: $sshHost,
                        prompt: Text("host, user@host, or config alias")
                    )
                    .onSubmit(addHost)
                } header: {
                    Text("New SSH Host")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Uses OpenSSH with your SSH config, agent, and Keychain. Passwords are not stored by this app.")
                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if !workspace.savedSSHHosts.isEmpty {
                    Section {
                        ForEach(workspace.savedSSHHosts, id: \.self) { host in
                            savedHostRow(host)
                        }
                    } header: {
                        Text("Saved Hosts")
                    } footer: {
                        Text("Active Agent Browser sessions from these hosts appear in the sidebar automatically.")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add Host", action: addHost)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddHost)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: workspace.savedSSHHosts.isEmpty ? 310 : 430)
    }

    private func savedHostRow(_ host: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(AgentBrowserDiscoveryTarget.ssh(host).displayHost)
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            let count = workspace.sessionCount(forSSHHost: host)
            Text(count == 1 ? "1 session" : "\(count) sessions")
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                workspace.removeSSHHost(host)
            } label: {
                Label("Forget \(host)", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private var trimmedHost: String {
        sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddHost: Bool {
        AgentBrowserDiscoveryService.isValidSSHHost(trimmedHost)
            && !workspace.savedSSHHosts.contains {
                $0.caseInsensitiveCompare(trimmedHost) == .orderedSame
            }
    }

    private func addHost() {
        guard canAddHost else { return }
        do {
            try workspace.addSSHHost(trimmedHost)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
