import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var workspace: BrowserWorkspace

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { workspace.isSidebarVisible ? .all : .detailOnly },
                set: { workspace.isSidebarVisible = $0 != .detailOnly }
            )
        ) {
            BrowserSidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 380)
        } detail: {
            BrowserStage()
        }
        .inspector(isPresented: inspectorPresentation) {
            BrowserInspector()
                .inspectorColumnWidth(min: 290, ideal: 290, max: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(SeamlessWindowToolbar())
        .sheet(isPresented: $workspace.isPresentingHostManager) {
            HostManagementSheet()
        }
        .alert("Agent Browser Companion", isPresented: Binding(
            get: { workspace.presentedError != nil },
            set: { if !$0 { workspace.presentedError = nil } }
        )) {
            Button("OK") { workspace.presentedError = nil }
        } message: {
            Text(workspace.presentedError?.message ?? "")
        }
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { workspace.selectedSession != nil && workspace.isInspectorVisible },
            set: { workspace.isInspectorVisible = $0 }
        )
    }
}

private struct SeamlessWindowToolbar: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}
