import Foundation

public protocol PRReviewServicing: Sendable {
    func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot
    func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                body: String, comments: [PRReviewDraftComment]) async throws
}

public struct PRReviewSnapshot: Equatable, Sendable {
    public let key: PullRequestKey
    public let title: String
    public let body: String
    public let author: String
    public let createdAt: Date?
    public let updatedAt: Date
    public let headSHA: String
    public let baseSHA: String
    public let files: [PRSearchFile]
    public let notices: [String]
    public let comments: [PRReviewComment]
    public let checksSummary: String
    public let comparisonBaseSHA: String?
    public let fileListComplete: Bool

    public init(key: PullRequestKey, title: String, body: String, author: String, createdAt: Date?,
                updatedAt: Date, headSHA: String, baseSHA: String, files: [PRSearchFile],
                notices: [String], comments: [PRReviewComment], checksSummary: String,
                comparisonBaseSHA: String? = nil, fileListComplete: Bool = false) {
        self.key = key; self.title = title; self.body = body; self.author = author
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.headSHA = headSHA; self.baseSHA = baseSHA; self.files = files
        self.notices = notices; self.comments = comments; self.checksSummary = checksSummary
        self.comparisonBaseSHA = comparisonBaseSHA
        self.fileListComplete = fileListComplete
    }

    public func canDraftInlineComment(in path: String) -> Bool {
        comparisonBaseSHA == nil && fileListComplete
            && files.contains { $0.path == path && $0.hasCompletePatch }
    }
}

public enum PRReviewEvent: String, Codable, CaseIterable, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
}

public struct PRReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    public enum Side: String, Codable, CaseIterable, Sendable { case left = "LEFT", right = "RIGHT" }
    public let id: UUID
    public let path: String
    public let line: Int
    public let side: Side
    public var body: String
    /// Comparison coordinates must never be sent as pull-request diff coordinates.
    public let comparisonBaseSHA: String?

    public init(id: UUID = UUID(), path: String, line: Int, side: Side, body: String,
                comparisonBaseSHA: String? = nil) {
        self.id = id; self.path = path; self.line = line; self.side = side; self.body = body
        self.comparisonBaseSHA = comparisonBaseSHA
    }
}

public struct PRReviewComment: Equatable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let body: String
    public let path: String?
    public let line: Int?
    public let url: URL?
    public let createdAt: Date?
    public let replyToID: String?

    public init(id: String, author: String, body: String, path: String? = nil, line: Int? = nil,
                url: URL? = nil, createdAt: Date? = nil, replyToID: String? = nil) {
        self.id = id; self.author = author; self.body = body; self.path = path; self.line = line
        self.url = url; self.createdAt = createdAt; self.replyToID = replyToID
    }
}

public enum PRReviewError: Error, Equatable, Sendable, LocalizedError {
    case connectionRequired, accountMismatch, invalidResponse, revisionChanged
    case invalidComment, comparisonDraft, invalidReview, submissionRejected

    public var errorDescription: String? {
        switch self {
        case .connectionRequired: "Connect the selected GitHub account before reviewing."
        case .accountMismatch: "The verified GitHub account or host does not match this review."
        case .invalidResponse: "GitHub returned an invalid review response."
        case .revisionChanged: "The pull request changed. Reload it and review your drafts before submitting."
        case .invalidComment: "A draft is not on a complete, current diff line. Reload and check its path, side, and line."
        case .comparisonDraft: "Comparison lines cannot receive review comments. Return to the full PR diff and recreate the draft."
        case .invalidReview: "Provide a review body for Comment or Request Changes and nonempty inline comments."
        case .submissionRejected: "GitHub rejected this review. Check your review and permissions; your drafts remain local."
        }
    }
}
