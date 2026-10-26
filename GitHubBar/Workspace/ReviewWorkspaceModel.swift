import Foundation
import GitHubBarCore
import Observation

enum ReviewWorkspaceMode: String, CaseIterable { case manage = "Manage PRs", review = "Review" }
enum ReviewWorkspaceTab: String, CaseIterable { case overview = "Overview", changes = "Changes", threads = "Threads", workspace = "Workspace" }
enum ReviewWorkspaceQueue: String, CaseIterable {
    case attention = "Needs attention", mine = "My pull requests", requested = "Requested reviews"
    case pinned = "Pinned", snoozed = "Snoozed", all = "All PRs"
    var icon: String {
        switch self {
        case .attention: "tray.and.arrow.down"
        case .mine: "person.crop.circle"
        case .requested: "eye"
        case .pinned: "pin"
        case .snoozed: "moon"
        case .all: "tray.full"
        }
    }
}

struct ReviewLineSelection: Equatable {
    let path: String
    let line: Int
    let side: String
    let text: String
}

@MainActor
@Observable
final class ReviewWorkspaceModel {
    var mode: ReviewWorkspaceMode = .manage
    var tab: ReviewWorkspaceTab = .overview
    var queue: ReviewWorkspaceQueue = .attention
    var search = ""
    var showsAgent = true
    var splitDiff = false
    var selection: ReviewLineSelection?
    var question = ""
    var inlineBody = ""
    private var selectedFilePath: String?
    private(set) var snapshot: PRReviewSnapshot?
    private(set) var loading = false
    private(set) var submitting = false
    private(set) var chatting = false
    private(set) var sinceLastReview = false
    var errorMessage: String?
    var notice: String?
    private(set) var citations: [ReviewChatCitation] = []
    let local: ReviewWorkspaceState
    @ObservationIgnored private let service: any PRReviewServicing
    @ObservationIgnored private let chatService: any ReviewChatServicing
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var submitTask: Task<Void, Never>?
    @ObservationIgnored private(set) var chatTask: Task<Void, Never>?
    private var key: PullRequestKey?
    private var account: String?
    private var generation = 0
    private var chatGeneration = 0

    init(service: any PRReviewServicing = PRReviewClient(),
         chatService: any ReviewChatServicing = ReviewChatClient(),
         local: ReviewWorkspaceState = ReviewWorkspaceState()) {
        self.service = service; self.chatService = chatService; self.local = local
    }

    var identity: ReviewIdentity? {
        guard let snapshot, let account else { return nil }
        return ReviewIdentity(account: account, prURL: snapshot.key.url.absoluteString,
            headSHA: snapshot.headSHA, baseSHA: snapshot.baseSHA)
    }
    var draft: WorkspaceReviewDraft { identity.map(local.draft) ?? WorkspaceReviewDraft() }
    var selectedFile: PRSearchFile? {
        snapshot?.files.first { $0.path == (selectedFilePath ?? draft.selectedFile) } ?? snapshot?.files.first
    }
    var baseline: String? {
        guard let account, let key else { return nil }
        return local.lastReviewedSHA(ReviewIdentity(account: account, prURL: key.url.absoluteString, headSHA: ""))
    }

    func select(_ key: PullRequestKey?, account: String?, force: Bool = false) {
        let account = account?.lowercased()
        guard force || self.key != key || self.account != account else { return }
        let changedPR = self.key != key || self.account != account
        self.key = key; self.account = account
        if changedPR { sinceLastReview = false; question = ""; inlineBody = "" }
        generation += 1
        let revision = generation
        loadTask?.cancel(); stopChat()
        selection = nil; selectedFilePath = nil; citations = []; errorMessage = nil; notice = nil
        let comparison = sinceLastReview ? baseline : nil
        snapshot = nil
        guard let key, let account, !account.isEmpty else { loading = false; return }
        loading = true
        loadTask = Task { [weak self, service] in
            do {
                let loaded = try await service.load(key: key, accountLogin: account, sinceSHA: comparison)
                guard let self, revision == generation, !Task.isCancelled else { return }
                snapshot = loaded
                loading = false
            } catch {
                guard let self, revision == generation, !Task.isCancelled else { return }
                loading = false
                errorMessage = "Could not load this PR: \(error.localizedDescription)"
            }
        }
    }

    func refresh() { select(key, account: account, force: true) }
    func compareSinceLastReview(_ enabled: Bool) {
        guard !enabled || baseline != nil else { return }
        sinceLastReview = enabled
        refresh()
    }
    @discardableResult
    func editDraft(_ edit: (inout WorkspaceReviewDraft) -> Void) -> Bool {
        guard let identity, !submitting, local.canSave else { return false }
        var value = local.draft(for: identity)
        edit(&value)
        return local.save(value, for: identity)
    }
    func selectFile(_ path: String) {
        selectedFilePath = path
        editDraft { $0.selectedFile = path }
        selection = nil
    }
    func markViewed(_ path: String, viewed: Bool) {
        editDraft { if viewed { $0.viewedFiles.insert(path) } else { $0.viewedFiles.remove(path) } }
    }
    func addInlineDraft() {
        guard let selection, !sinceLastReview, !inlineBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard local.canSave else {
            errorMessage = local.errorMessage ?? "Local review state cannot be saved. Your comment is still in the editor."
            return
        }
        guard snapshot?.canDraftInlineComment(in: selection.path) == true else {
            errorMessage = "This diff is incomplete. Read or comment on this file on GitHub."
            return
        }
        let comment = WorkspaceInlineDraft(path: selection.path, line: selection.line, side: selection.side, body: inlineBody)
        guard editDraft({ $0.comments.append(comment) }) else { return }
        inlineBody = ""
        self.selection = nil
    }
    func markReviewed() {
        guard let identity else { return }
        guard local.markReviewed(identity) else { errorMessage = local.errorMessage; return }
        notice = "Review position saved for commit \(identity.headSHA.prefix(8))."
    }

    func submit(event: PRReviewEvent, target: ReviewIdentity) {
        guard let identity, identity == target else {
            errorMessage = "The PR, account, or diff changed. Reopen the review sheet after reviewing the current changes."
            return
        }
        guard !submitting, let snapshot, !sinceLastReview, local.canSave else { return }
        let submitted = draft
        guard event.rawValue != "COMMENT" || submitted.hasUnsubmittedComments else { return }
        let revision = generation
        submitting = true; errorMessage = nil
        submitTask = Task { [weak self, service] in
            guard let self else { return }
            defer { submitting = false }
            do {
                let comments = submitted.comments.compactMap { comment -> PRReviewDraftComment? in
                    guard let side = PRReviewDraftComment.Side(rawValue: comment.side) else { return nil }
                    return PRReviewDraftComment(path: comment.path, line: comment.line, side: side, body: comment.body)
                }
                guard comments.count == submitted.comments.count else {
                    throw NSError(domain: "GitHubBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "An inline comment has an invalid side."])
                }
                try await service.submit(key: snapshot.key, accountLogin: identity.account,
                    headSHA: identity.headSHA, baseSHA: identity.baseSHA, event: event, body: submitted.body, comments: comments)
                var saved = local.draft(for: identity)
                saved.body = ""; saved.comments = []
                local.save(saved, for: identity)
                local.markReviewed(identity)
                guard revision == generation else { return }
                notice = "Review submitted to GitHub."
            } catch {
                guard revision == generation else { return }
                errorMessage = "Review was not confirmed: \(error.localizedDescription) Your draft is retained. Check GitHub before retrying."
            }
        }
    }

    func sendQuestion(configuration: ReviewChatConfiguration, policy: String) {
        guard !chatting, local.canSave, let identity, let snapshot else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let revision = generation
        chatGeneration += 1
        let chatRevision = chatGeneration
        var context = "\(snapshot.title)\n\(snapshot.body)\n"
        if let selection { context += "Selected \(selection.path):\(selection.line) \(selection.side)\n\(selection.text)\n" }
        for file in snapshot.files {
            guard context.count < 40_000 else { break }
            let excerpt = String((file.patch ?? "Patch unavailable").prefix(max(0, 40_000 - context.count)))
            context += "\nFile: \(file.path)\n\(excerpt)\n"
        }
        context = String(context.prefix(40_000)) + "\nContext may be truncated; say when evidence is missing."
        let messages = draft.messages.suffix(20).map {
            ReviewChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text)
        }
        var request = ReviewChatRequest(accountLogin: identity.account, prURL: identity.prURL,
            headSHA: identity.headSHA, question: prompt, context: context, policy: policy, messages: messages)
        // Bound the actual JSON bytes, including escaped source and multi-byte text.
        func requestSize() -> Int { (try? JSONEncoder().encode(request).count) ?? Int.max }
        while requestSize() > 750_000, !request.messages.isEmpty { request.messages.removeFirst() }
        while requestSize() > 750_000, !request.context.isEmpty {
            request.context = String(request.context.prefix(request.context.count / 2))
        }
        guard requestSize() <= 750_000 else {
            errorMessage = "This question is too large for the chat adapter. Shorten it and try again."
            return
        }
        appendMessage(WorkspaceChatMessage(role: "user", text: prompt), for: identity)
        question = ""; chatting = true; errorMessage = nil; citations = []
        chatTask = Task { [weak self, chatService] in
            do {
                let response = try await chatService.send(request, configuration: configuration)
                guard let self, generation == revision, chatGeneration == chatRevision, !Task.isCancelled else { return }
                chatting = false
                appendMessage(WorkspaceChatMessage(role: "assistant", text: response.answer), for: identity)
                citations = response.citations
            } catch {
                guard let self, generation == revision, chatGeneration == chatRevision, !Task.isCancelled else { return }
                chatting = false
                question = prompt
                errorMessage = "Agent could not answer: \(error.localizedDescription)"
            }
        }
    }

    func stopChat() {
        chatGeneration += 1; chatTask?.cancel(); chatting = false
    }

    private func appendMessage(_ message: WorkspaceChatMessage, for identity: ReviewIdentity) {
        var saved = local.draft(for: identity)
        saved.messages.append(message)
        local.save(saved, for: identity)
    }

    func follow(_ citation: ReviewChatCitation) {
        guard let file = snapshot?.files.first(where: { $0.path == citation.path }),
              let patch = file.patch,
              let line = PRDiffParser.parse(patch).first(where: {
                  citation.side == "LEFT" ? $0.oldLine == citation.line : $0.newLine == citation.line
              }) else {
            errorMessage = "That citation is outside the available diff. Open the file on GitHub for more context."
            return
        }
        selectFile(file.path)
        selection = ReviewLineSelection(path: file.path, line: citation.line, side: citation.side, text: line.text)
        tab = .changes
    }
}
