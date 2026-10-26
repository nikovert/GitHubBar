import AppKit
import GitHubBarCore
import XCTest
import SwiftUI
@testable import GitHubBarCore
@testable import GitHubBar

@MainActor
final class PRNavigationTests: XCTestCase {
    func testMenuSecondaryClickDoesNotPerformWorkspaceAction() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var workspaceSelections: [BoardSubject?] = []
        let controller = menu(workspace: fixture.model, actions: AppActions(
            openWorkspace: { workspaceSelections.append($0) },
            openGitHub: { _ in }
        ))
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let row = try XCTUnwrap(controller.statusMenu.items.first { $0.title.hasPrefix("#42:") }?.view)

        row.rightMouseUp(with: mouseEvent(.rightMouseUp))

        XCTAssertTrue(workspaceSelections.isEmpty, "Secondary click must never select the workspace")
    }

    func testMenuPrimaryKeyboardAndSecondaryHaveSeparateRoutes() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var opened: [PullRequestPresentation] = []
        var urls: [URL] = []
        let controller = menu(workspace: fixture.model, actions: AppActions(
            openPullRequest: { opened.append($0) }, openGitHub: { urls.append($0) }
        ))
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let item = try XCTUnwrap(controller.statusMenu.items.first { $0.title.hasPrefix("#42:") })
        let row = try XCTUnwrap(item.view)
        row.mouseUp(with: mouseEvent(.leftMouseUp))
        XCTAssertEqual(opened, [pullRequest()])
        XCTAssertTrue(urls.isEmpty)
        row.rightMouseUp(with: mouseEvent(.rightMouseUp))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(urls, [pullRequest().url])
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(opened.count, 3)
    }

    func testExternalSearchSelectionHydratesBoardAndSurvivesReload() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pr = pullRequest()
        fixture.model.openPullRequest(pr)
        await fixture.model.reload()
        let subject = try XCTUnwrap(fixture.model.selectedSubject)
        XCTAssertEqual(subject, .pullRequest(try PullRequestKey(url: pr.url)))
        let rows = fixture.model.pullRequests(in: .empty)
        let details = try XCTUnwrap(BoardSubjectDetails.resolve(subject: subject, pullRequests: rows, stacks: []))
        XCTAssertEqual(details.primary.title, "External PR with useful metadata")
        XCTAssertEqual(details.primary.author?.displayName, "Alice")
        XCTAssertEqual(details.primary.requestedReviewers?.map(\.displayName), ["Bob"])
        XCTAssertEqual(details.primary.state, .merged)
        XCTAssertEqual(details.primary.headSHA, "head-42")
        XCTAssertEqual(rows.count, 1)
        var workload = AppPresentationState.empty
        workload.needsYourReview = [pr]
        XCTAssertEqual(fixture.model.pullRequests(in: workload).count, 1)
    }

    func testSearchRowPrimaryAndSecondaryClicksHaveSeparateRoutes() async throws {
        var opened: [PullRequestPresentation] = []
        var urls: [URL] = []
        let pr = pullRequest()
        let result = PRSearchResult(pullRequest: pr, source: .title, excerpt: "Matched title",
            path: nil, lineKind: nil, coverage: PRSearchCoverage(), score: 1)
        let host = NSHostingView(rootView: PRSearchResultRow(result: result,
            openPullRequest: { opened.append($0) }, openGitHub: { urls.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 220)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        func send(_ type: NSEvent.EventType) {
            let point = host.convert(NSPoint(x: 100, y: host.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.sendEvent(event)
        }
        send(.leftMouseDown)
        send(.leftMouseUp)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, [pr])
        XCTAssertTrue(urls.isEmpty)
        send(.rightMouseDown)
        send(.rightMouseUp)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, [pr])
        XCTAssertEqual(urls, [pr.url])
    }

    func testAccountSwitchClearsExternalSelectionAndMetadata() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "first", accessCoverage: AccessCoverage(isComplete: true))
        fixture.model.updateWorkload(state)
        fixture.model.openPullRequest(pullRequest())
        XCTAssertEqual(fixture.model.pullRequests(in: state).count, 1)
        state.accountConnection = .connected(login: "second", accessCoverage: AccessCoverage(isComplete: true))
        fixture.model.updateWorkload(state)
        XCTAssertNil(fixture.model.selectedSubject)
        XCTAssertTrue(fixture.model.pullRequests(in: state).isEmpty)
    }

    func testStackSummaryOpensDisplayedPRAndRetainsSubmenu() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var opened: [PullRequestPresentation] = []
        let controller = menu(workspace: fixture.model, actions: AppActions(
            openPullRequest: { opened.append($0) }, openGitHub: { _ in }
        ), stack: true)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let item = try XCTUnwrap(controller.statusMenu.items.first { $0.title.hasPrefix("#42:") })
        let submenu = try XCTUnwrap(item.submenu)
        let row = try XCTUnwrap(item.view)
        row.mouseUp(with: mouseEvent(.leftMouseUp))
        XCTAssertEqual(opened.map(\.number), [42])
        XCTAssertTrue(submenu.items.contains { $0.title == "View stack on GitHub ↗" })
        XCTAssertTrue(submenu.items.contains { $0.title == "Workspace for stack…" })
        let member = try XCTUnwrap(submenu.items.first { $0.title.hasPrefix("#42:") }?.view)
        XCTAssertTrue(member.accessibilityPerformPress())
        XCTAssertEqual(opened.map(\.number), [42, 42])
    }

    func testPinnedSessionKeepsExplicitJumpWithoutTakingOverPrimaryClick() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: pullRequest().url))
        let store = LocalWorkspaceStore(directoryURL: fixture.directory)
        try await store.update { document in
            document.setSession(AgentSessionLink(subject: subject, agent: .codex,
                worktreePath: fixture.directory.path, tmuxSessionName: "test-session", state: .running))
        }
        await fixture.model.reload()
        var opened: [PullRequestPresentation] = []
        let controller = menu(workspace: fixture.model, actions: AppActions(
            openPullRequest: { opened.append($0) }, openGitHub: { _ in }
        ))
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let item = try XCTUnwrap(controller.statusMenu.items.first { $0.title.hasPrefix("#42:") })
        XCTAssertTrue(item.submenu?.items.contains { $0.title == "Jump to Codex session" } == true)
        item.view?.mouseUp(with: mouseEvent(.leftMouseUp))
        XCTAssertEqual(opened, [pullRequest()])
    }

    private func menu(workspace: WorkspaceModel, actions: AppActions, stack: Bool = false) -> StatusItemController {
        var state = AppPresentationState.empty
        state.needsYourReview = [pullRequest(stack: stack)]
        if stack { state.pullRequestStacks = [PullRequestStack(id: "stack", number: 42, pullRequests: state.needsYourReview)] }
        return StatusItemController(
            appModel: AppModel(engine: WorkloadEngine(), initialState: state),
            actions: actions, workspaceModel: workspace, avatarImageCache: AvatarImageCache()
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func fixture() -> (directory: URL, model: WorkspaceModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pr-navigation-\(UUID())")
        let store = LocalWorkspaceStore(directoryURL: directory)
        return (directory, WorkspaceModel(store: store,
            sessions: AgentSessionManager(store: store, tmuxURL: nil),
            reviewStore: AgentReviewStore(directoryURL: directory)))
    }

    private func pullRequest(stack: Bool = false) -> PullRequestPresentation {
        PullRequestPresentation(id: "external", repositoryID: "repo", repositoryNameWithOwner: "example/repo",
            number: 42, title: "External PR with useful metadata", url: URL(string: "https://github.com/example/repo/pull/42")!,
            isDraft: false, state: .merged,
            author: PullRequestAuthorPresentation(id: "author", displayName: "Alice", avatarURL: nil),
            reviewDecision: .approved,
            stackMembership: stack ? PullRequestStackMembership(id: "stack", number: 42, size: 1, position: 1) : nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            requestedReviewers: [ReviewerPresentation(id: "reviewer", displayName: "Bob", avatarURL: nil, kind: .person)],
            reviewers: [], headSHA: "head-42")
    }
}
