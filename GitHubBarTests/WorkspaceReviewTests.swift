import Foundation
import GitHubBarCore
import XCTest
@testable import GitHubBar

@MainActor
final class WorkspaceReviewTests: XCTestCase {
    func testContextUsesOutstandingHumansAndPreservesUnknownRoster() {
        let requested = [reviewer("me", .person), reviewer("giles", .bot), reviewer("team", .team)]
        let context = WorkspaceReviewContext.make(
            pullRequest(requested: requested), accountLogin: "me", stackURL: nil
        )
        XCTAssertEqual(context.requestedHumans, ["me"])
        XCTAssertEqual(context.requestedTeamCount, 1)
        XCTAssertTrue(context.reviewersComplete)
        XCTAssertEqual(context.headSHA, "head-1")
        XCTAssertEqual(context.priority(in: .empty).rank, 1)

        let unknown = WorkspaceReviewContext.make(
            pullRequest(requested: nil), accountLogin: "me", stackURL: nil
        )
        XCTAssertFalse(unknown.reviewersComplete)
        XCTAssertTrue(unknown.requestedHumans.isEmpty)
        XCTAssertEqual(unknown.priority(in: .empty).rank, 1)
    }

    func testSortingUsesEffectivePriorityThenOldestGitHubUpdate() throws {
        let old = context(number: 1, updatedAt: 10)
        let recent = context(number: 2, updatedAt: 20)
        var manual = context(number: 3, updatedAt: 30)
        manual.authorLogin = "Reina234"
        var board = LocalWorkspaceDocument.empty
        board.setEntry(BoardEntry(
            subject: .pullRequest(try PullRequestKey(url: URL(string: manual.prURL)!)), priority: .high
        ))

        let sorted = [recent, manual, old].sorted {
            WorkspaceReviewContext.precedes($0, $1, in: board)
        }

        XCTAssertEqual(sorted.map(\.prURL), [manual.prURL, old.prURL, recent.prURL])
        XCTAssertEqual(manual.priority(in: board).reason, "Manual priority")
    }

    func testAutomaticPriorityPreservesNotesAndTags() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: pullRequest().url))
        try await fixture.store.update {
            $0.setEntry(BoardEntry(subject: subject, priority: .high, tagIDs: ["blocked"], note: "Keep me"))
        }
        await fixture.model.reload()

        fixture.model.setPriority(.none, for: subject)
        await eventually { fixture.model.document.entry(for: subject)?.priority == nil }

        let entry = try await fixture.store.load().entry(for: subject)
        XCTAssertNil(entry?.priority)
        XCTAssertEqual(entry?.note, "Keep me")
        XCTAssertEqual(entry?.tagIDs, ["blocked"])
    }

    func testWorkloadSyncDoesNotNeedWindowOrEnableIntegration() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "me", accessCoverage: AccessCoverage(isComplete: true))
        state.needsYourReview = [pullRequest(requested: [reviewer("me", .person)])]

        fixture.model.updateWorkload(state)
        await eventually { fixture.model.reviewDocument.contexts.count == 1 }

        let loaded = try await fixture.reviews.load()
        XCTAssertFalse(loaded.enabled)
        XCTAssertEqual(loaded.accountLogin, "")
        XCTAssertEqual(loaded.contexts.values.first?.priority(in: .empty).rank, 3)
        XCTAssertNotNil(fixture.model.reviewUnavailableReason(for: fixture.model.reviewContext(for: state.needsYourReview[0])))
    }

    func testAccountMismatchRejectsEnableAndContextSync() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.reviews.update { $0.accountLogin = "someone-else" }
        await fixture.model.reload()
        fixture.model.updateWorkload(state())
        await eventually { fixture.model.errorMessage != nil }
        fixture.model.errorMessage = nil

        fixture.model.configureReviews(enabled: true)
        await eventually { fixture.model.errorMessage != nil }

        let loaded = try await fixture.reviews.load()
        XCTAssertEqual(loaded.accountLogin, "someone-else")
        XCTAssertFalse(loaded.enabled)
        XCTAssertTrue(loaded.contexts.isEmpty)
        XCTAssertTrue(fixture.model.reviewAccountMismatch)
    }

    func testPollingPreservesNewerWorkerContext() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var fresh = context(number: 1, updatedAt: 100)
        fresh.headSHA = "worker-new-head"
        let workerContext = fresh
        try await fixture.reviews.update { $0.contexts[workerContext.prURL] = workerContext }
        await fixture.model.reload()
        var callbacks = 0
        fixture.model.onDocumentChange = { callbacks += 1 }

        fixture.model.updateWorkload(state())
        await fixture.model.reload()
        await fixture.model.reload()

        let loaded = try await fixture.reviews.load()
        XCTAssertEqual(loaded.contexts[workerContext.prURL], workerContext)
        XCTAssertEqual(fixture.model.reviewContext(for: pullRequest()), workerContext)
        XCTAssertEqual(callbacks, 0)
        XCTAssertFalse(WorkspaceReviewContext.shouldSync(context(number: 1), replacing: workerContext))
        XCTAssertFalse(WorkspaceReviewContext.shouldSync(workerContext, replacing: workerContext))
        XCTAssertTrue(WorkspaceReviewContext.shouldSync(workerContext, replacing: nil))
    }

    func testContextDoesNotUseAnotherAccountsNewerMetadata() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var fresh = context(number: 1, updatedAt: 100)
        fresh.accountLogin = "other"
        fresh.headSHA = "other-accounts-head"
        let otherContext = fresh
        try await fixture.reviews.update { $0.contexts[otherContext.prURL] = otherContext }
        await fixture.model.reload()
        fixture.model.updateWorkload(state())

        XCTAssertEqual(fixture.model.reviewContext(for: pullRequest()).headSHA, "head-1")
    }

    func testRequestRequiresAuthorSHAAndMatchingAccountAndSupportsRerequest() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.reviews.update { $0.accountLogin = "me"; $0.enabled = true }
        await fixture.model.reload()
        fixture.model.updateWorkload(state())
        await eventually { fixture.model.reviewDocument.contexts.count == 1 }
        let valid = fixture.model.reviewContext(for: pullRequest())
        var missingSHA = valid
        missingSHA.headSHA = ""
        var missingAuthor = valid
        missingAuthor.authorLogin = ""
        var wrongAccount = valid
        wrongAccount.accountLogin = "other"
        XCTAssertNotNil(fixture.model.reviewUnavailableReason(for: missingSHA))
        XCTAssertNotNil(fixture.model.reviewUnavailableReason(for: missingAuthor))
        XCTAssertNotNil(fixture.model.reviewUnavailableReason(for: wrongAccount))
        XCTAssertNil(fixture.model.reviewUnavailableReason(for: valid))

        fixture.model.requestReview(valid)
        await eventually { fixture.model.reviewDocument.jobs.count == 1 }
        XCTAssertNotNil(fixture.model.reviewUnavailableReason(for: valid))
        try await fixture.reviews.update { $0.jobs[0].status = .completed }
        await fixture.model.reload()
        fixture.model.requestReview(valid)
        await eventually { fixture.model.reviewDocument.jobs.count == 2 }
    }

    func testClearingPolicyFieldPreservesOtherFields() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: pullRequest().url))
        let url = subject.key.url.absoluteString
        try await fixture.reviews.update {
            $0.accountLogin = "me"
            $0.policyOverrides[url] = AgentReviewPolicy(fixMode: .all, comments: false, replies: true)
        }
        await fixture.model.reload()
        fixture.model.updateWorkload(state())
        await eventually { fixture.model.reviewDocument.contexts.count == 1 }

        fixture.model.setReviewFixMode(nil, for: subject)
        await eventually { fixture.model.reviewPolicy(for: subject).fixMode == nil }

        let loaded = try await fixture.reviews.load()
        XCTAssertNil(loaded.policyOverrides[url]?.fixMode)
        XCTAssertEqual(loaded.policyOverrides[url]?.comments, false)
        XCTAssertEqual(loaded.policyOverrides[url]?.replies, true)
    }

    func testLatestJobShowsStaleForChangedSHA() throws {
        var document = AgentReviewDocument()
        document.enabled = true
        document.accountLogin = "me"
        let job = try document.enqueue(context: context(number: 1), source: "board", now: .now)

        XCTAssertTrue(WorkspaceReviewContext.status(job, currentSHA: "new-sha").contains("Stale"))
        XCTAssertEqual(WorkspaceReviewContext.status(job, currentSHA: job.headSHA), "Queued")
    }

    private func fixture() -> (
        directory: URL, store: LocalWorkspaceStore, reviews: AgentReviewStore, model: WorkspaceModel
    ) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/workspace-tests/\(UUID().uuidString)")
        let store = LocalWorkspaceStore(directoryURL: directory)
        let reviews = AgentReviewStore(directoryURL: directory)
        return (directory, store, reviews, WorkspaceModel(
            store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil), reviewStore: reviews
        ))
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for workspace update", file: file, line: line)
    }

    private func state() -> AppPresentationState {
        var value = AppPresentationState.empty
        value.accountConnection = .connected(login: "me", accessCoverage: AccessCoverage(isComplete: true))
        value.needsYourReview = [pullRequest()]
        return value
    }

    private func reviewer(_ login: String, _ kind: ReviewerPresentation.Kind) -> ReviewerPresentation {
        ReviewerPresentation(id: login, displayName: login, avatarURL: nil, kind: kind)
    }

    private func pullRequest(requested: [ReviewerPresentation]? = []) -> PullRequestPresentation {
        PullRequestPresentation(
            id: "pr", repositoryID: "repo", repositoryNameWithOwner: "org/repo", number: 1,
            title: "A pull request", url: URL(string: "https://github.com/org/repo/pull/1")!,
            isDraft: false,
            author: PullRequestAuthorPresentation(id: "author", displayName: "author", avatarURL: nil),
            updatedAt: Date(timeIntervalSince1970: 10), requestedReviewers: requested,
            reviewers: [reviewer("not-outstanding", .person)], headSHA: "head-1"
        )
    }

    private func context(number: Int, updatedAt: TimeInterval = 10) -> AgentPRContext {
        AgentPRContext(
            prURL: "https://github.com/org/repo/pull/\(number)", authorLogin: "author",
            accountLogin: "me", headSHA: "head-1", updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
