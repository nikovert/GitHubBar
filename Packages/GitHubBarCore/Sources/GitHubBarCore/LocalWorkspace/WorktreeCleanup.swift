import Foundation

public struct WorktreeCleanupPRSummary: Identifiable, Equatable, Sendable {
    public var id: PullRequestKey { key }
    public let key: PullRequestKey
    public let title: String
    public let description: String

    public init(key: PullRequestKey, title: String, body: String) {
        self.key = key
        self.title = title
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        description = text.count > 280 ? String(text.prefix(277)) + "…" : text
    }
}

public struct WorktreeCleanupPR: Equatable, Sendable {
    public var title: String
    public var body: String
    public var stackPullRequests: [WorktreeCleanupPRSummary]
    public var headSHA: String
    public var merged: Bool
    public var hasStack: Bool
    public var stackComplete: Bool
    public var stackMerged: Bool
    public init(title: String, headSHA: String, merged: Bool, hasStack: Bool = false, stackComplete: Bool = true, stackMerged: Bool = true,
                body: String = "", stackPullRequests: [WorktreeCleanupPRSummary] = []) {
        self.title = title; self.headSHA = headSHA; self.merged = merged
        self.body = body; self.stackPullRequests = stackPullRequests
        self.hasStack = hasStack
        self.stackComplete = stackComplete; self.stackMerged = stackMerged
    }
}

public struct WorktreeCleanupSessionIdentity: Equatable, Sendable {
    public let id: String
    public let serverPID: Int
    public let serverStartedAt: Int
    public let sessionCreatedAt: Int
}

public protocol WorktreeCleanupGitHubChecking: Sendable {
    func check(_ subject: BoardSubject, accountLogin: String) async throws -> WorktreeCleanupPR
}

public struct WorktreeCleanupCandidate: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let sessions: [AgentSessionLink]
    public let title: String
    public let headSHA: String
    public let skipReason: String?
    public let liveSessions: [String: WorktreeCleanupSessionIdentity]
    public let accountLogin: String
    public let configuration: WorkspaceConfiguration
    public var pullRequests: [WorktreeCleanupPRSummary] = []
    public var isEligible: Bool { skipReason == nil }
}

public struct WorktreeCleanupResult: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable { case removed, skipped, failed }
    public var id: String { path }
    public let path: String
    public let outcome: Outcome
    public let message: String
}

public protocol WorktreeCleanupServicing: Sendable {
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate]
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult]
}

public actor WorktreeCleanupCoordinator: WorktreeCleanupServicing {
    private let store: LocalWorkspaceStore
    private let sessions: AgentSessionManager
    private let github: any WorktreeCleanupGitHubChecking
    private let local: WorktreeCleanupLocal

    public init(store: LocalWorkspaceStore, sessions: AgentSessionManager,
                github: any WorktreeCleanupGitHubChecking = WorktreeCleanupGitHubClient(),
                commandRunner: any CommandRunning = ProcessCommandRunner(),
                tmuxURL: URL? = AgentSessionManager.findExecutable("tmux")) {
        self.store = store; self.sessions = sessions; self.github = github
        local = WorktreeCleanupLocal(runner: commandRunner, tmuxURL: tmuxURL)
    }

    public func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] {
        try await sessions.exclusively { [self] in
            let document = try await store.load()
            var candidates: [WorktreeCleanupCandidate] = []
            let groups = Dictionary(grouping: document.sessions, by: { WorktreeCleanupLocal.canonical($0.worktreePath) })
            for path in groups.keys.sorted() {
                try Task.checkCancellation()
                candidates.append(await inspect(path: path, document: document, accountLogin: accountLogin))
            }
            return candidates
        }
    }

    public func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        do {
            return try await sessions.exclusively { [self] in
                var results: [WorktreeCleanupResult] = []
                var visited = Set<String>()
                for candidate in approved where visited.insert(candidate.path).inserted {
                    if Task.isCancelled { break }
                    results.append(await remove(candidate, accountLogin: accountLogin))
                }
                return results
            }
        } catch {
            return approved.map { WorktreeCleanupResult(path: $0.path, outcome: .skipped, message: error.localizedDescription) }
        }
    }

    private func inspect(path: String, document: LocalWorkspaceDocument, accountLogin: String) async -> WorktreeCleanupCandidate {
        let links = document.sessions.filter { WorktreeCleanupLocal.canonical($0.worktreePath) == path }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var title = links.first?.subject.key.description ?? path
        var sha = ""
        var live: [String: WorktreeCleanupSessionIdentity] = [:]
        var reason: String?
        var pullRequests: [WorktreeCleanupPRSummary] = []
        do {
            guard !accountLogin.isEmpty else { throw CleanupBlocked("Connect a monitored account first.") }
            let subjects = Set(links.map(\.subject)).sorted { $0.key.description < $1.key.description }
            var metadata: [BoardSubject: WorktreeCleanupPR] = [:]
            var metadataError: (any Error)?
            for subject in subjects {
                try Task.checkCancellation()
                do {
                    let pr = try await github.check(subject, accountLogin: accountLogin)
                    metadata[subject] = pr
                    let summaries = [WorktreeCleanupPRSummary(key: subject.key, title: pr.title, body: pr.body)] + pr.stackPullRequests
                    for summary in summaries where !pullRequests.contains(where: { $0.key == summary.key }) {
                        pullRequests.append(summary)
                    }
                } catch { metadataError = error }
            }
            title = pullRequests.first?.title ?? title
            try await local.validate(path: path, links: links, configuration: document.configuration)
            if let metadataError { throw metadataError }
            for subject in subjects {
                guard let pr = metadata[subject] else { throw CleanupBlocked("PR information is unavailable.") }
                guard pr.merged else { throw CleanupBlocked("The PR is not merged.") }
                let wasStack: Bool
                if case .stack = subject { wasStack = true } else { wasStack = false }
                if pr.hasStack || wasStack {
                    guard pr.stackComplete, pr.stackMerged else { throw CleanupBlocked("The complete stack must be verified merged.") }
                }
                try await local.verifyOriginHead(path: path, subject: subject, sha: pr.headSHA)
                if !sha.isEmpty, sha != pr.headSHA { throw CleanupBlocked("Linked PRs have different heads.") }
                sha = pr.headSHA
            }
            live = try await local.liveSessions(path: path, links: links)
            try Task.checkCancellation()
        } catch { reason = error.localizedDescription }
        return WorktreeCleanupCandidate(path: path, sessions: links, title: title, headSHA: sha,
            skipReason: reason, liveSessions: live, accountLogin: accountLogin,
            configuration: document.configuration, pullRequests: pullRequests)
    }

    private func remove(_ candidate: WorktreeCleanupCandidate, accountLogin: String) async -> WorktreeCleanupResult {
        var started = false
        do {
            guard candidate.isEligible, candidate.accountLogin == accountLogin else {
                throw CleanupBlocked("Account or eligibility changed. Scan again.")
            }
            let document = try await store.load()
            try unchanged(candidate, document: document)
            let fresh = await inspect(path: candidate.path, document: document, accountLogin: accountLogin)
            guard fresh.isEligible else { throw CleanupBlocked(fresh.skipReason ?? "No longer eligible.") }
            guard fresh.headSHA == candidate.headSHA, fresh.liveSessions == candidate.liveSessions else {
                throw CleanupBlocked("HEAD or live sessions changed. Scan again before stopping anything.")
            }
            try unchanged(candidate, document: await store.load())
            try await local.validate(path: candidate.path, links: candidate.sessions, configuration: candidate.configuration)
            try await local.requireHead(candidate.headSHA, path: candidate.path)
            try Task.checkCancellation()
            started = true
            var remaining = candidate.liveSessions
            for (name, identity) in candidate.liveSessions.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                try unchanged(candidate, document: await store.load())
                let current = try await local.liveSessions(path: candidate.path, links: candidate.sessions)
                guard current == remaining else { throw CleanupBlocked("Session activity changed; cleanup stopped. Scan again.") }
                try await local.stop(sessionID: identity.id)
                remaining.removeValue(forKey: name)
            }
            try Task.checkCancellation()
            try unchanged(candidate, document: await store.load())
            guard try await local.liveSessions(path: candidate.path, links: candidate.sessions).isEmpty else {
                throw CleanupBlocked("A session is still attached. Worktree retained.")
            }
            try await local.requireNoLocalProcesses(path: candidate.path)
            try await local.validate(path: candidate.path, links: candidate.sessions, configuration: candidate.configuration)
            try await local.requireHead(candidate.headSHA, path: candidate.path)
            try Task.checkCancellation()
            try await local.remove(path: candidate.path, configuration: candidate.configuration, links: candidate.sessions)
            let ids = Set(candidate.sessions.map(\.id))
            try await store.update { document in
                for id in ids { document.removeSession(id: id) }
            }
            return WorktreeCleanupResult(path: candidate.path, outcome: .removed,
                message: "Removed worktree and session links. Local branch and board history retained.")
        } catch {
            return WorktreeCleanupResult(path: candidate.path, outcome: started ? .failed : .skipped,
                message: error.localizedDescription)
        }
    }

    private func unchanged(_ candidate: WorktreeCleanupCandidate, document: LocalWorkspaceDocument) throws {
        let links = document.sessions.filter { WorktreeCleanupLocal.canonical($0.worktreePath) == candidate.path }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        // State and heartbeat updates are not changes of ownership.
        func identity(_ s: AgentSessionLink) -> AgentSessionLink {
            var value = s; value.state = .stopped; value.lastSeenAt = nil; return value
        }
        guard document.configuration == candidate.configuration,
              links.map(identity) == candidate.sessions.map(identity) else {
            throw CleanupBlocked("Workspace configuration or linked sessions changed. Scan again.")
        }
    }
}

struct CleanupBlocked: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
