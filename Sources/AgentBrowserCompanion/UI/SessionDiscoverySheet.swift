import SwiftUI

struct SessionDiscoverySheet: View {
    private enum Location: String, CaseIterable, Identifiable {
        case known = "Known Hosts"
        case ssh = "New SSH Host"

        var id: String { rawValue }
    }

    @EnvironmentObject private var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var location: Location = .known
    @State private var sshHost = ""
    @State private var sessions: [DiscoveredAgentBrowserSession] = []
    @State private var selectedSessionIDs: Set<String> = []
    @State private var isDiscovering = false
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var discoveryResults: [DiscoveryResult] = []
    @State private var discoveryTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add Sessions")
                    .font(.title2.weight(.semibold))
                Text("Find active Agent Browser sessions on this Mac or through SSH.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form {
                Section {
                    Picker("Location", selection: $location) {
                        ForEach(Location.allCases) { location in
                            Text(location.rawValue).tag(location)
                        }
                    }
                    .pickerStyle(.segmented)

                    if location == .ssh {
                        TextField("SSH Host", text: $sshHost, prompt: Text("host, user@host, or config alias"))
                            .onSubmit(discover)
                    }
                } footer: {
                    if location == .ssh {
                        Text("Uses OpenSSH with your SSH config, agent, and Keychain. Passwords are not stored by this app.")
                    }
                }

                browserSessionSections
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: discover)
                    .disabled(!canDiscover || isDiscovering || isAdding)
                Button(addButtonTitle, action: addSelected)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedSessions.isEmpty || isDiscovering || isAdding)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
        .onAppear(perform: discover)
        .onChange(of: location) {
            discoveryTask?.cancel()
            sessions = []
            selectedSessionIDs = []
            errorMessage = nil
            hasSearched = false
            discoveryResults = []
            if location == .known { discover() }
        }
        .onDisappear { discoveryTask?.cancel() }
    }

    @ViewBuilder
    private var browserSessionSections: some View {
        if shouldGroupSessionsByHost, !isDiscovering {
            ForEach(discoveryTargets, id: \.self) { target in
                Section(target.displayHost) {
                    discoveryResultContent(for: target)
                }
            }
        } else {
            Section("Browser Sessions") {
                browserSessionSectionContent
            }
        }
    }

    @ViewBuilder
    private func discoveryResultContent(for target: AgentBrowserDiscoveryTarget) -> some View {
        if let result = discoveryResults.first(where: { $0.target == target }) {
            if !result.sessions.isEmpty {
                ForEach(result.sessions) { session in
                    discoveredRow(session)
                }
            } else if let error = result.error {
                compactState(
                    "Host Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: error
                )
            } else {
                Text("No active Agent Browser sessions.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No active Agent Browser sessions.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var browserSessionSectionContent: some View {
        if isDiscovering {
            HStack {
                Spacer()
                ProgressView("Searching for sessions…")
                Spacer()
            }
            .padding(.vertical, 12)
        } else if let errorMessage {
            compactState(
                "Couldn't Find Sessions",
                systemImage: "exclamationmark.triangle",
                description: errorMessage
            )
        } else if sessions.isEmpty {
            ContentUnavailableView {
                Label(
                    emptyTitle,
                    systemImage: location == .known ? "desktopcomputer" : "network"
                )
            } description: {
                Text(emptyDescription)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ForEach(sessions) { session in
                discoveredRow(session)
            }
        }
    }

    @ViewBuilder
    private func discoveredRow(_ session: DiscoveredAgentBrowserSession) -> some View {
        let isAdded = workspace.isDiscoveredSessionAdded(session)
        HStack(spacing: 10) {
            Toggle("", isOn: selectionBinding(for: session))
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: session.source.location == .local ? "desktopcomputer" : "network")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(1)
                Text(session.detailLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(isAdded ? "Added" : session.statusLabel)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isAdded || !session.streamingEnabled || !session.browserConnected)
    }

    private var canDiscover: Bool {
        location == .known || AgentBrowserDiscoveryService.isValidSSHHost(sshHost)
    }

    private var discoveryTargets: [AgentBrowserDiscoveryTarget] {
        switch location {
        case .known:
            workspace.knownDiscoveryTargets
        case .ssh:
            [.ssh(sshHost.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
    }

    private var shouldGroupSessionsByHost: Bool {
        location == .known && discoveryTargets.count > 1
    }

    private var selectedSessions: [DiscoveredAgentBrowserSession] {
        sessions.filter { selectedSessionIDs.contains($0.id) && !workspace.isDiscoveredSessionAdded($0) }
    }

    private var emptyDescription: String {
        if !hasSearched {
            return location == .known
                ? "Search this Mac and previously connected hosts for active Agent Browser sessions."
                : "Enter a hostname, user@host, or SSH config alias above to find its Agent Browser sessions."
        }
        return "Make sure Agent Browser is running with streaming enabled, then try again."
    }

    private var emptyTitle: String {
        if hasSearched { return "No Browser Sessions Found" }
        return location == .known ? "Ready to Search" : "Enter an SSH Host"
    }

    private var addButtonTitle: String {
        switch selectedSessions.count {
        case 1:
            "Add Session"
        case 2...:
            "Add \(selectedSessions.count) Sessions"
        default:
            "Add Sessions"
        }
    }

    private func compactState(
        _ title: String,
        systemImage: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func selectionBinding(for session: DiscoveredAgentBrowserSession) -> Binding<Bool> {
        Binding(
            get: { selectedSessionIDs.contains(session.id) },
            set: { isSelected in
                if isSelected {
                    selectedSessionIDs.insert(session.id)
                } else {
                    selectedSessionIDs.remove(session.id)
                }
            }
        )
    }

    private func discover() {
        guard canDiscover else { return }
        discoveryTask?.cancel()
        isDiscovering = true
        errorMessage = nil
        discoveryResults = []
        selectedSessionIDs = []
        let targets = discoveryTargets

        discoveryTask = Task {
            let results = await withTaskGroup(of: DiscoveryResult.self) { group in
                for target in targets {
                    group.addTask {
                        do {
                            return DiscoveryResult(
                                target: target,
                                sessions: try await AgentBrowserDiscoveryService.discover(target),
                                error: nil
                            )
                        } catch {
                            return DiscoveryResult(
                                target: target,
                                sessions: [],
                                error: error.localizedDescription
                            )
                        }
                    }
                }

                var results: [DiscoveryResult] = []
                for await result in group { results.append(result) }
                return results
            }

            guard !Task.isCancelled else { return }
            discoveryResults = results.sorted {
                $0.target.displayHost.localizedCaseInsensitiveCompare($1.target.displayHost) == .orderedAscending
            }
            let discovered = results.flatMap(\.sessions)
            sessions = discovered.sorted {
                if $0.source.displayHost != $1.source.displayHost {
                    return $0.source.displayHost.localizedCaseInsensitiveCompare($1.source.displayHost) == .orderedAscending
                }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
            selectedSessionIDs = Set(sessions.filter {
                    $0.streamingEnabled && $0.browserConnected && !workspace.isDiscoveredSessionAdded($0)
            }.map(\.id))

            if sessions.isEmpty {
                let failures = results.compactMap { result -> String? in
                    guard let error = result.error else { return nil }
                    return "\(result.target.displayHost): \(error)"
                }
                if failures.count == targets.count {
                    errorMessage = failures.joined(separator: "\n")
                }
            }
            hasSearched = true
            isDiscovering = false
        }
    }

    private struct DiscoveryResult {
        let target: AgentBrowserDiscoveryTarget
        let sessions: [DiscoveredAgentBrowserSession]
        let error: String?
    }

    private func addSelected() {
        let additions = selectedSessions
        guard !additions.isEmpty else { return }
        isAdding = true
        errorMessage = nil
        Task {
            do {
                for session in additions {
                    try await workspace.addDiscoveredSession(session)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAdding = false
            }
        }
    }
}
