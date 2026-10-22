import Foundation
import GitHubBarCore
import XCTest
@testable import GitHubBar

@MainActor
final class WorkspaceErrorTests: XCTestCase {
    func testBackgroundReloadDoesNotDismissAnActionError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-error-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalWorkspaceStore(directoryURL: directory)
        let workspace = WorkspaceModel(
            store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil)
        )
        workspace.errorMessage = "Could not create worktree"

        await workspace.reload()

        XCTAssertEqual(workspace.errorMessage, "Could not create worktree")
    }
}
