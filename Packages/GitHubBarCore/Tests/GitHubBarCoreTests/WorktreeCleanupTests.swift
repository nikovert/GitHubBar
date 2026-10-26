import Foundation
import XCTest
@testable import GitHubBarCore

final class WorktreeCleanupTests: XCTestCase {
    func testSkippedWorktreeStillShowsPRAndStackDescriptions() async throws {
        let f = try await CleanupFixture.make(stack: true)
        defer { f.dispose() }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first)
        XCTAssertFalse(row.isEligible)
        XCTAssertEqual(row.title, "A useful change")
        XCTAssertEqual(row.pullRequests.map(\.key.number), [12, 13])
        XCTAssertEqual(row.pullRequests.map(\.title), ["A useful change", "Follow-up change"])
        XCTAssertEqual(row.pullRequests.map(\.description), ["Handle missing inputs. Keep the fallback active.", "Update the caller."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
    }

    func testDescriptionExcerptHandlesEmptyMultilineAndLongUnicodeText() throws {
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!)
        let empty = WorktreeCleanupPRSummary(key: key, title: "Empty", body: " \n\t")
        XCTAssertEqual(empty.description, "")
        let long = WorktreeCleanupPRSummary(key: key, title: "Long", body: String(repeating: "👨‍👩‍👧‍👦 ", count: 200))
        XCTAssertLessThanOrEqual(long.description.count, 280)
        XCTAssertTrue(long.description.hasSuffix("…"))
        XCTAssertFalse(long.description.contains("\n"))
    }

    func testOrdinaryPRLinkRespectsCurrentUnmergedStack() async throws {
        let f = try await CleanupFixture.make(metadata: CleanupMetadata(stackMerged: false))
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
    }

    func testNewLinkedSessionBeforeFirstStopInvalidatesWholeApproval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let id = UUID()
        let name = "githubbar-claude-widget-pr-12-\(id.uuidString.prefix(8).lowercased())"
        try await f.store.update { $0.setSession(AgentSessionLink(id: id, subject: f.subject, agent: .claude,
            worktreePath: f.path, tmuxSessionName: name, managedWorktree: true, state: .stopped)) }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.appearBeforeStop(name: name)
        _ = await f.coordinator.execute(preview, accountLogin: "tester")
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty, "A changed full session set must stop no sessions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testRestartedTmuxServerWithReusedIDInvalidatesApproval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.restartServer()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.skipped])
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }
    func testLingeringProcessRetainsWorktreeAfterApprovedStop() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.leaveLingeringProcess()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.failed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        let doc = try await f.store.load()
        XCTAssertEqual(doc.sessions.count, 1)
    }
    func testSymlinkToAnotherWorktreeCannotBecomeCleanupTarget() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let alias = f.root.appendingPathComponent("worktrees/alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: f.path)
        try await f.store.update { doc in
            let s = doc.sessions[0]
            doc.sessions[0] = AgentSessionLink(id: s.id, subject: s.subject, agent: s.agent,
                worktreePath: alias, tmuxSessionName: s.tmuxSessionName, managedWorktree: true)
        }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testRemovalFailureRetainsLinksAndDoesNotForce() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.refuseRemoval()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.failed])
        let doc = try await f.store.load()
        XCTAssertEqual(doc.sessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testManagerRejectsRestartWhileCleanupOwnsLifecycle() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let stored = try await f.store.load()
        let session = try XCTUnwrap(stored.sessions.first)
        let manager = AgentSessionManager(store: f.store, commandRunner: f.runner, tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        let gate = CleanupTestGate()
        let task = Task { try await manager.exclusively { await gate.pause() } }
        await gate.waitForStart()
        do { _ = try await manager.restart(id: session.id); XCTFail("Restart must not race cleanup") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already in progress")) }
        await gate.resume()
        try await task.value
    }

    func testExistingRemoveDoesNotStopDirtySession() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
        let stored = try await f.store.load()
        let session = try XCTUnwrap(stored.sessions.first)
        let manager = AgentSessionManager(store: f.store, commandRunner: f.runner, tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        do { try await manager.removeManagedWorktree(id: session.id); XCTFail() }
        catch AgentSessionLaunchError.dirtyWorktree {}
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
    }
    func testMergedSyncedWorktreeIsRemovedButBranchAndNotesRemain() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let preview = try await fixture.coordinator.preview(accountLogin: "tester")
        XCTAssertEqual(preview.count, 1)
        XCTAssertTrue(try XCTUnwrap(preview.first).isEligible, preview.first?.skipReason ?? "")
        XCTAssertEqual(preview.first?.pullRequests.first?.description, "Handle missing inputs. Keep the fallback active.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let results = await fixture.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        let document = try await fixture.store.load()
        XCTAssertTrue(document.sessions.isEmpty)
        XCTAssertEqual(document.entries.first?.note, "Keep this note")
        let branch = try await fixture.git(["rev-parse", "refs/heads/topic"])
        XCTAssertEqual(branch, fixture.sha)
        let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/cleanup"])
        XCTAssertTrue(refs.isEmpty)
    }

    func testUnsafeWorktreesAreSkippedWithoutStoppingSessions() async throws {
        for change in ["dirty", "staged", "untracked", "ignored", "ahead", "locked", "origin", "fetch", "external", "main", "missing", "hidden"] {
            let f = try await CleanupFixture.make(running: true)
            defer { f.dispose() }
            switch change {
            case "dirty": try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
            case "staged":
                try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
                _ = try await f.git(["add", "file"], path: f.path)
            case "untracked": try Data("keep".utf8).write(to: URL(fileURLWithPath: f.path + "/extra"))
            case "ignored": try Data("secret".utf8).write(to: URL(fileURLWithPath: f.path + "/local.env"))
            case "ahead": _ = try await f.git(["commit", "--allow-empty", "-qm", "Unpushed"], path: f.path)
            case "locked": _ = try await f.git(["worktree", "lock", f.path])
            case "origin": _ = try await f.git(["remote", "set-url", "origin", "https://github.com/other/repo.git"])
            case "fetch": await f.runner.setFetchFailure()
            case "external": try await f.store.update { doc in
                let s = doc.sessions[0]
                doc.sessions[0] = AgentSessionLink(id: s.id, subject: s.subject, agent: s.agent,
                    worktreePath: s.worktreePath, tmuxSessionName: s.tmuxSessionName, managedWorktree: false)
            }
            case "main": try await f.store.update { doc in
                let s = doc.sessions[0]
                doc.configuration.worktreeRoot = f.root.path
                doc.sessions[0] = AgentSessionLink(id: s.id, subject: s.subject, agent: s.agent,
                    worktreePath: f.checkout, tmuxSessionName: s.tmuxSessionName, managedWorktree: true)
            }
            case "missing": _ = try await f.git(["worktree", "remove", f.path])
            case "hidden": _ = try await f.git(["update-index", "--assume-unchanged", "file"], path: f.path)
            default: break
            }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertFalse(try XCTUnwrap(preview.first).isEligible, change)
            _ = await f.coordinator.execute(preview, accountLogin: "tester")
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
            let sessions = try await f.store.load().sessions
            XCTAssertEqual(sessions.count, 1, change)
        }
    }

    func testChangedPreviewNeverStopsAgents() async throws {
        for change in ["dirty", "head", "config", "session", "account", "liveID"] {
            let f = try await CleanupFixture.make(running: true)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertTrue(try XCTUnwrap(preview.first).isEligible)
            switch change {
            case "dirty": try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
            case "head": _ = try await f.git(["commit", "--allow-empty", "-qm", "Late commit"], path: f.path)
            case "config": try await f.store.update { $0.configuration.codexCommand = "changed" }
            case "session": try await f.store.update { $0.setSession(AgentSessionLink(
                subject: f.subject, agent: .claude, worktreePath: f.path, tmuxSessionName: "external")) }
            case "liveID": await f.runner.replaceSessionID()
            default: break
            }
            let results = await f.coordinator.execute(preview, accountLogin: change == "account" ? "other" : "tester")
            XCTAssertEqual(results.map(\.outcome), [.skipped], change)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), change)
        }
    }

    func testStopsApprovedSessionAndRechecksForWritesBeforeRemoval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.writeOnStop()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertNotEqual(results.map(\.outcome), [.removed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path + "/late.txt"))
        let sessions = try await f.store.load().sessions
        XCTAssertEqual(sessions.count, 1)
        let kills = await f.runner.kills
        XCTAssertEqual(kills, ["$1"])
    }

    func testLiveApprovedSessionIsStoppedBeforeRemoval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.removed])
        let kills = await f.runner.kills
        XCTAssertEqual(kills, ["$1"])
    }

    func testDuplicateLinksAreGroupedAndUnknownSessionsBlockCleanup() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        try await f.store.update { $0.setSession(AgentSessionLink(subject: f.subject, agent: .claude,
            worktreePath: f.path, tmuxSessionName: nil, managedWorktree: true, state: .stopped)) }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertEqual(preview.count, 1)
        XCTAssertEqual(preview.first?.sessions.count, 2)
        await f.runner.addUnknownSession()
        let blocked = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertFalse(try XCTUnwrap(blocked.first).isEligible)
    }

    func testUnmergedOrIncompleteStackIsBlocked() async throws {
        for metadata in [CleanupMetadata(merged: false), CleanupMetadata(merged: true, stackComplete: false),
                         CleanupMetadata(merged: true, stackMerged: false)] {
            let f = try await CleanupFixture.make(metadata: metadata, stack: true)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
        }
    }

    func testSquashMergeWithDeletedBranchUsesRetainedPRHead() async throws {
        let f = try await CleanupFixture.make(stack: true)
        defer { f.dispose() }
        // Origin has only refs/pull/12/head; its branches are unrelated to this PR.
        _ = try await f.git(["commit", "--allow-empty", "-qm", "Squash merge on main"])
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertTrue(try XCTUnwrap(preview.first).isEligible)
        let result = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(result.map(\.outcome), [.removed])
    }
}

private struct CleanupMetadata: Sendable {
    var merged = true
    var stackComplete = true
    var stackMerged = true
}

private struct CleanupGitHub: WorktreeCleanupGitHubChecking {
    let sha: String
    let metadata: CleanupMetadata
    func check(_ subject: BoardSubject, accountLogin: String) async throws -> WorktreeCleanupPR {
        let memberKey = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/13")!)
        return WorktreeCleanupPR(title: "A useful change", headSHA: sha, merged: metadata.merged,
            hasStack: true, stackComplete: metadata.stackComplete, stackMerged: metadata.stackMerged,
            body: "Handle missing inputs.\n\nKeep the fallback active.", stackPullRequests: [
                WorktreeCleanupPRSummary(key: subject.key, title: "Root duplicate", body: "Duplicate"),
                WorktreeCleanupPRSummary(key: memberKey, title: "Follow-up change", body: "Update the caller."),
            ])
    }
}

private struct CleanupFixture: Sendable {
    let root: URL
    let checkout: String
    let path: String
    let sha: String
    let subject: BoardSubject
    let store: LocalWorkspaceStore
    let runner: CleanupRunner
    let coordinator: WorktreeCleanupCoordinator

    static func make(running: Bool = false, metadata: CleanupMetadata = CleanupMetadata(), stack: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = root.appendingPathComponent("checkout").path
        let path = root.appendingPathComponent("worktrees/pr12").path
        let remote = root.appendingPathComponent("origin.git").path
        try await runGit(["init", "-q", checkout])
        try await runGit(["-C", checkout, "config", "user.name", "Test"])
        try await runGit(["-C", checkout, "config", "user.email", "test@example.invalid"])
        try Data("original".utf8).write(to: URL(fileURLWithPath: checkout + "/file"))
        try Data("*.env\n".utf8).write(to: URL(fileURLWithPath: checkout + "/.gitignore"))
        try await runGit(["-C", checkout, "add", "."])
        try await runGit(["-C", checkout, "commit", "-qm", "Initial"])
        let sha = try await runGit(["-C", checkout, "rev-parse", "HEAD"])
        try await runGit(["init", "--bare", "-q", remote])
        try await runGit(["-C", checkout, "push", "-q", remote, "HEAD:refs/pull/12/head"])
        try await runGit(["-C", checkout, "remote", "add", "origin", "https://github.com/acme/widget.git"])
        try await runGit(["-C", checkout, "worktree", "add", "-qb", "topic", path])
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!)
        let subject: BoardSubject = stack ? .stack(key) : .pullRequest(key)
        let id = UUID()
        let name = "githubbar-codex-widget-pr-12-\(id.uuidString.prefix(8).lowercased())"
        let session = AgentSessionLink(id: id, subject: subject, agent: .codex, worktreePath: path,
            tmuxSessionName: name, managedWorktree: true, state: running ? .running : .stopped)
        let store = LocalWorkspaceStore(directoryURL: root.appendingPathComponent("board"))
        var document = LocalWorkspaceDocument.empty
        document.configuration = WorkspaceConfiguration(repositoryCheckouts: ["acme/widget": checkout],
            worktreeRoot: root.appendingPathComponent("worktrees").path)
        document.setSession(session)
        document.setEntry(BoardEntry(subject: subject, note: "Keep this note"))
        try await store.save(document)
        let runner = CleanupRunner(remote: remote, path: path, name: name, running: running)
        let manager = AgentSessionManager(store: store, commandRunner: runner, tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        let coordinator = WorktreeCleanupCoordinator(store: store, sessions: manager,
            github: CleanupGitHub(sha: sha, metadata: metadata), commandRunner: runner,
            tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        return Self(root: root, checkout: checkout, path: path, sha: sha, subject: subject,
            store: store, runner: runner, coordinator: coordinator)
    }

    func git(_ args: [String], path: String? = nil) async throws -> String {
        try await Self.runGit(["-C", path ?? checkout] + args)
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
    @discardableResult
    static func runGit(_ args: [String]) async throws -> String {
        let r = await ProcessCommandRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, environment: [:])
        guard r.exitCode == 0 else { throw NSError(domain: "TestGit", code: Int(r.exitCode), userInfo: [NSLocalizedDescriptionKey: r.standardError]) }
        return r.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor CleanupRunner: CommandRunning {
    let remote: String
    let path: String
    let name: String
    var running: Bool
    var liveID = "$1"
    var unknown = false
    var failFetch = false
    var writesOnStop = false
    var removalFails = false
    var lingering = false
    var serverPID = 100
    var listCalls = 0
    var appearingName: String?
    private(set) var kills: [String] = []
    init(remote: String, path: String, name: String, running: Bool) {
        self.remote = remote; self.path = path; self.name = name; self.running = running
    }
    func setFetchFailure() { failFetch = true }
    func replaceSessionID() { liveID = "$2" }
    func addUnknownSession() { unknown = true }
    func writeOnStop() { writesOnStop = true }
    func refuseRemoval() { removalFails = true }
    func leaveLingeringProcess() { lingering = true }
    func restartServer() { serverPID = 200 }
    func appearBeforeStop(name: String) { appearingName = name }
    func run(executableURL: URL, arguments: [String], environment: [String: String]) async -> CommandResult {
        if executableURL.lastPathComponent == "lsof" {
            return CommandResult(exitCode: 0, standardOutput: lingering ? "p123\nn\(path)\n" : "", standardError: "")
        }
        if executableURL.path == "/fake/tmux" {
            if arguments.first == "list-panes" {
                listCalls += 1
                let suffix = arguments.last?.contains("#{pid}") == true ? "\t\(serverPID)\t1700000000\t1700000001" : ""
                return CommandResult(exitCode: 0, standardOutput:
                    (running ? "\(liveID)\t\(name)\t\(path)\(suffix)\n" : "") +
                    (unknown ? "$99\tunknown\t\(path)\(suffix)\n" : "") +
                    (listCalls >= 3 ? appearingName.map { "$2\t\($0)\t\(path)\(suffix)\n" } ?? "" : ""), standardError: "")
            }
            if arguments.first == "kill-session" {
                kills.append(arguments.last!); running = false
                if writesOnStop { try? Data("keep".utf8).write(to: URL(fileURLWithPath: path + "/late.txt")) }
            }
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        var args = arguments
        if args.contains("worktree"), args.contains("remove"), removalFails {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "Refused")
        }
        if args.contains("fetch"), let index = args.firstIndex(of: "origin") {
            if failFetch { return CommandResult(exitCode: 1, standardOutput: "", standardError: "Offline") }
            args[index] = remote
        }
        return await ProcessCommandRunner().run(executableURL: executableURL, arguments: args, environment: environment)
    }
}

private actor CleanupTestGate {
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func waitForStart() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
