import AppKit
import GitHubBarCore
import SwiftUI

@MainActor
final class WorkspaceWindowController {
    private let appModel: AppModel
    private let workspaceModel: WorkspaceModel
    private var window: NSWindow?

    init(appModel: AppModel, workspaceModel: WorkspaceModel) {
        self.appModel = appModel
        self.workspaceModel = workspaceModel
    }

    func show(subject: BoardSubject? = nil) {
        if let subject { workspaceModel.selectedSubject = subject }
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await workspaceModel.reload() }
    }

    func show(pullRequest: PullRequestPresentation) {
        workspaceModel.openPullRequest(pullRequest)
        show()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitHubBar Workspace"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 780, height: 590)
        window.contentView = NSHostingView(
            rootView: WorkspaceBoardView(workspace: workspaceModel, appModel: appModel)
        )
        window.center()
        return window
    }
}
