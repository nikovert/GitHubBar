import AppKit
import GitHubBarCore
import Observation

private enum WorkspaceAction: Hashable {
    case priority(BoardSubject)
    case tag(BoardSubject, String)
    case note(BoardSubject)
    case checkout(String)
    case worktreeRoot
    case saveTag(String)
    case launch(BoardSubject, AgentKind)
    case pin(BoardSubject, AgentKind)
    case stop(UUID)
    case restart(UUID)
    case unlink(UUID)
    case removeWorktree(UUID)
    case focus(UUID)
    case configureReview
    case reviewPolicy(BoardSubject?)
    case review(String)
    case openReviewWorktree(String)
}

@MainActor
@Observable
final class WorkspaceModel {
    private(set) var document: LocalWorkspaceDocument = .empty
    private(set) var reviewDocument = AgentReviewDocument()
    private(set) var monitoredAccountLogin: String?
    private(set) var reviewContexts: [String: AgentPRContext] = [:]
    var selectedSubject: BoardSubject?
    var errorMessage: String?

    @ObservationIgnored private let store: LocalWorkspaceStore
    @ObservationIgnored private let sessions: AgentSessionManager
    @ObservationIgnored private let reviewStore: AgentReviewStore
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var failedAction: WorkspaceAction?
    private var pendingActions: Set<WorkspaceAction> = []
    @ObservationIgnored private var contextSyncTask: Task<Void, Never>?
    @ObservationIgnored var onDocumentChange: (() -> Void)?

    init(
        store: LocalWorkspaceStore,
        sessions: AgentSessionManager,
        reviewStore: AgentReviewStore = AgentReviewStore()
    ) {
        self.store = store
        self.sessions = sessions
        self.reviewStore = reviewStore
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.sessions.refreshStates()
                await self?.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func reload() async {
        do {
            let loaded = try await store.load()
            if loaded != document {
                document = loaded
                onDocumentChange?()
            }
        } catch {
            if errorMessage == nil {
                errorMessage = "Could not read the local workspace: \(error.localizedDescription)"
            }
        }
        do {
            let loaded = try await reviewStore.load()
            if loaded != reviewDocument {
                reviewDocument = loaded
                onDocumentChange?()
            }
            syncReviewContexts()
        } catch {
            if errorMessage == nil {
                errorMessage = "Could not read agent reviews: \(error.localizedDescription)"
            }
        }
    }

    func setPriority(_ priority: BoardPriority, for subject: BoardSubject) {
        updateEntry(subject, action: .priority(subject)) {
            $0.priority = priority == .none ? nil : priority
        }
    }

    func updateWorkload(_ state: AppPresentationState) {
        if case let .connected(login, _) = state.accountConnection {
            monitoredAccountLogin = login
        } else {
            monitoredAccountLogin = nil
        }
        reviewContexts = WorkspaceReviewContext.contexts(in: state)
        syncReviewContexts()
    }

    private func syncReviewContexts() {
        guard contextSyncTask == nil, !reviewContexts.isEmpty,
              reviewContexts.contains(where: {
                  WorkspaceReviewContext.shouldSync($0.value, replacing: reviewDocument.contexts[$0.key])
              })
        else { return }
        contextSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { contextSyncTask = nil }
            do {
                var snapshot: [String: AgentPRContext]
                repeat {
                    snapshot = reviewContexts
                    let contexts = snapshot
                    let loaded = try await reviewStore.update { document in
                        for context in contexts.values {
                            let valid = try context.validated()
                            guard document.accountLogin.isEmpty ||
                                    document.accountLogin.lowercased() == valid.accountLogin.lowercased()
                            else {
                                throw AgentReviewError.invalid("Agent reviews are configured for a different GitHub account. Use a separate workspace for this account.")
                            }
                            if WorkspaceReviewContext.shouldSync(valid, replacing: document.contexts[valid.prURL]) {
                                document.contexts[valid.prURL] = valid
                            }
                        }
                    }
                    if reviewDocument != loaded {
                        reviewDocument = loaded
                        onDocumentChange?()
                    }
                } while snapshot != reviewContexts
            } catch {
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        }
    }

    func reviewContext(for pullRequest: PullRequestPresentation) -> AgentPRContext {
        let url = (try? PullRequestKey(url: pullRequest.url))?.url.absoluteString
            ?? pullRequest.url.absoluteString
        let current = reviewContexts[url] ?? WorkspaceReviewContext.make(
            pullRequest, accountLogin: monitoredAccountLogin ?? "", stackURL: nil
        )
        if let stored = reviewDocument.contexts[url],
           stored.accountLogin.lowercased() == current.accountLogin.lowercased(),
           stored.updatedAt > current.updatedAt {
            return stored
        }
        return current
    }

    var reviewAccountMismatch: Bool {
        guard let monitoredAccountLogin, !reviewDocument.accountLogin.isEmpty else { return false }
        return reviewDocument.accountLogin.lowercased() != monitoredAccountLogin.lowercased()
    }

    var canConfigureReviews: Bool {
        monitoredAccountLogin != nil && !reviewAccountMismatch &&
            !pendingActions.contains(.configureReview)
    }

    func configureReviews(enabled: Bool) {
        guard let login = monitoredAccountLogin else {
            errorMessage = "Connect a monitored GitHub account before configuring agent reviews."
            return
        }
        perform(.configureReview) { [reviewStore, store] in
            let input = try JSONSerialization.data(withJSONObject: [
                "op": "configure", "enabled": enabled, "account_login": login,
            ])
            _ = try await reviewStore.execute(input, workspace: store)
        }
    }

    func reviewPolicy(for subject: BoardSubject?) -> AgentReviewPolicy {
        guard let subject else { return reviewDocument.defaultPolicy }
        return reviewDocument.policyOverrides[Self.policyKey(subject)] ?? AgentReviewPolicy()
    }

    func reviewPriority(for context: AgentPRContext) -> AgentPriority {
        context.priority(in: document, priorityAuthors: reviewDocument.priorityAuthors)
    }

    func setReviewFixMode(_ value: AgentFixMode?, for subject: BoardSubject?) {
        updateReviewPolicy(for: subject) { $0.fixMode = value }
    }

    func setReviewComments(_ value: Bool?, for subject: BoardSubject?) {
        updateReviewPolicy(for: subject) { $0.comments = value }
    }

    func setReviewReplies(_ value: Bool?, for subject: BoardSubject?) {
        updateReviewPolicy(for: subject) { $0.replies = value }
    }

    private static func policyKey(_ subject: BoardSubject) -> String {
        switch subject {
        case .pullRequest: subject.key.url.absoluteString
        case .stack: "stack:\(subject.key.url.absoluteString)"
        }
    }

    private func updateReviewPolicy(
        for subject: BoardSubject?,
        edit: @escaping @Sendable (inout AgentReviewPolicy) -> Void
    ) {
        let login = monitoredAccountLogin
        let key = subject.map(Self.policyKey)
        perform(.reviewPolicy(subject)) { [reviewStore] in
            _ = try await reviewStore.update { document in
                guard let login, document.accountLogin.isEmpty ||
                        document.accountLogin.lowercased() == login.lowercased() else {
                    throw AgentReviewError.invalid("Agent review settings require the matching monitored GitHub account.")
                }
                if let key {
                    var policy = document.policyOverrides[key] ?? AgentReviewPolicy()
                    edit(&policy)
                    document.policyOverrides[key] = policy
                } else {
                    edit(&document.defaultPolicy)
                }
            }
        }
    }

    func latestReview(for context: AgentPRContext) -> AgentReviewJob? {
        reviewDocument.jobs.last { $0.context.prURL == context.prURL &&
            $0.context.accountLogin.lowercased() == context.accountLogin.lowercased() }
    }

    func reviewUnavailableReason(for context: AgentPRContext) -> String? {
        guard let login = monitoredAccountLogin, !login.isEmpty else {
            return "Connect a monitored GitHub account."
        }
        guard login.lowercased() == context.accountLogin.lowercased(), !reviewAccountMismatch else {
            return "Agent reviews are configured for a different GitHub account."
        }
        guard reviewDocument.enabled,
              reviewDocument.accountLogin.lowercased() == login.lowercased() else {
            return "Enable agent reviews for @\(login)."
        }
        guard !context.headSHA.isEmpty, !context.authorLogin.isEmpty else {
            return "Waiting for the PR's head SHA and author from GitHub."
        }
        if pendingActions.contains(.review(context.prURL)) { return "Requesting review…" }
        if reviewDocument.jobs.contains(where: { $0.context.prURL == context.prURL && $0.isActive }) {
            return "A review is already queued or running."
        }
        return nil
    }

    func requestReview(_ context: AgentPRContext) {
        if let reason = reviewUnavailableReason(for: context) {
            errorMessage = reason
            return
        }
        perform(.review(context.prURL)) { [reviewStore] in
            _ = try await reviewStore.update { document in
                _ = try document.enqueue(context: context, source: "board", now: .now)
            }
        }
    }

    func openReviewWorktree(_ path: String) {
        let action = WorkspaceAction.openReviewWorktree(path)
        beginAttempt(action)
        Task {
            do { try TerminalSessionOpener.openDirectory(path) }
            catch {
                errorMessage = "Could not open Terminal: \(error.localizedDescription)"
                failedAction = action
            }
        }
    }

    func setTag(_ id: String, enabled: Bool, currentIDs: Set<String>, for subject: BoardSubject) {
        updateEntry(subject, action: .tag(subject, id)) { entry in
            var tags = entry.tagIDs ?? currentIDs
            if enabled { tags.insert(id) } else { tags.remove(id) }
            entry.tagIDs = tags
        }
    }

    func setNote(_ note: String, for subject: BoardSubject) {
        updateEntry(subject, action: .note(subject)) { $0.note = note }
    }

    private func updateEntry(
        _ subject: BoardSubject,
        action: WorkspaceAction,
        edit: @escaping @Sendable (inout BoardEntry) -> Void
    ) {
        perform(action) { [store] in
            _ = try await store.update { document in
                var entry = document.entry(for: subject) ?? BoardEntry(subject: subject)
                edit(&entry)
                entry.updatedAt = .now
                entry.updatedBy = "local"
                document.setEntry(entry)
            }
        }
    }

    func saveCheckout(_ path: String, for repository: String) {
        perform(.checkout(repository)) { [store] in
            _ = try await store.update { $0.configuration.repositoryCheckouts[repository] = path }
        }
    }

    func saveWorktreeRoot(_ path: String) {
        perform(.worktreeRoot) { [store] in
            _ = try await store.update { $0.configuration.worktreeRoot = path }
        }
    }

    func saveTag(_ tag: BoardTag) {
        perform(.saveTag(tag.id)) { [store] in _ = try await store.update { $0.setTag(tag) } }
    }

    func createTag(name: String, color: BoardTagColor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = BoardTag(id: "custom-\(UUID().uuidString.lowercased())", name: trimmed, color: color)
        saveTag(tag)
    }

    func launch(_ agent: AgentKind, for subject: BoardSubject) {
        perform(.launch(subject, agent)) { [sessions] in
            _ = try await sessions.launch(subject: subject, agent: agent)
        }
    }

    func pin(_ agent: AgentKind, for subject: BoardSubject, path: String, tmuxName: String?) {
        perform(.pin(subject, agent)) { [sessions] in
            _ = try await sessions.pinExisting(
                subject: subject, agent: agent, worktreePath: path,
                tmuxSessionName: tmuxName?.isEmpty == true ? nil : tmuxName
            )
        }
    }

    func stopSession(_ id: UUID) {
        perform(.stop(id)) { [sessions] in try await sessions.stop(id: id) }
    }

    func restartSession(_ id: UUID) {
        perform(.restart(id)) { [sessions] in _ = try await sessions.restart(id: id) }
    }

    func unlinkSession(_ id: UUID) {
        perform(.unlink(id)) { [sessions] in try await sessions.unlink(id: id) }
    }

    func removeWorktree(_ id: UUID) {
        perform(.removeWorktree(id)) { [sessions] in
            try await sessions.removeManagedWorktree(id: id)
        }
    }

    func focus(_ session: AgentSessionLink) {
        let action = WorkspaceAction.focus(session.id)
        beginAttempt(action)
        do {
            try TerminalSessionOpener.open(session)
        } catch {
            errorMessage = "Could not open Terminal: \(error.localizedDescription)"
            failedAction = action
        }
    }

    private func beginAttempt(_ action: WorkspaceAction) {
        if failedAction == action {
            errorMessage = nil
            failedAction = nil
        }
    }

    private func perform(
        _ action: WorkspaceAction,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        beginAttempt(action)
        pendingActions.insert(action)
        Task {
            defer { pendingActions.remove(action) }
            do {
                try await operation()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
                failedAction = action
            }
        }
    }
}
