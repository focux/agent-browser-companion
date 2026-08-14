import SwiftUI

@main
struct AgentBrowserCompanionApp: App {
    @StateObject private var workspace = BrowserWorkspace()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(workspace)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    await workspace.connectSavedSessions()
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.automatic)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CompanionCommands(workspace: workspace)
        }

        Settings {
            SettingsView()
                .environmentObject(workspace)
        }
    }
}

private struct CompanionCommands: Commands {
    @ObservedObject var workspace: BrowserWorkspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Browser Sessions…") {
                workspace.isPresentingSessionDiscovery = true
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

        CommandMenu("Browser") {
            Button(workspace.isSidebarVisible ? "Hide Browser List" : "Show Browser List") {
                workspace.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button(workspace.isInspectorVisible ? "Hide Inspector" : "Show Inspector") {
                workspace.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button(workspace.isSelectedSessionInPictureInPicture ? "Return Session to Main Window" : "Add Session to Picture in Picture") {
                workspace.togglePictureInPicture()
            }
            .disabled(workspace.selectedSession == nil)
            .keyboardShortcut("p", modifiers: [.command, .option])
        }

    }
}
