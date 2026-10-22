import Foundation

public enum AgentSessionLaunchError: Error, LocalizedError, Sendable {
    case invalidPath
    case missingCheckout
    case missingExecutable(String)
    case commandFailed(String)
    case wrongRepositoryRemote(String)
    case unmanagedWorktree
    case dirtyWorktree

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Choose absolute checkout and worktree-root paths."
        case .missingCheckout: "Configure an existing local checkout for this repository."
        case let .missingExecutable(name): "Could not find \(name) in PATH or common install locations."
        case let .commandFailed(message): message
        case let .wrongRepositoryRemote(repository):
            "The checkout's origin must point to \(repository) on github.com."
        case .unmanagedWorktree: "Only GitHubBar-created worktrees can be removed here."
        case .dirtyWorktree: "The worktree has local changes and cannot be removed."
        }
    }
}

public struct AgentSessionLaunchPlan: Sendable {
    public let subject: BoardSubject
    public let agent: AgentKind
    public let checkoutPath: String
    public let worktreePath: String
    public let tmuxSessionName: String
    public let agentExecutablePath: String
    public let id: UUID

    public init(
        subject: BoardSubject,
        agent: AgentKind,
        checkoutPath: String,
        worktreeRoot: String,
        agentExecutablePath: String,
        id: UUID = UUID()
    ) throws {
        let checkout = URL(fileURLWithPath: checkoutPath).standardizedFileURL.path
        let root = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard checkoutPath.hasPrefix("/"), worktreeRoot.hasPrefix("/"),
              agentExecutablePath.hasPrefix("/"),
              root != "/", root != home, root != checkout,
              !root.hasPrefix(checkout + "/") else {
            throw AgentSessionLaunchError.invalidPath
        }
        let suffix = String(id.uuidString.prefix(8)).lowercased()
        let stem = "\(subject.key.repository)-pr-\(subject.key.number)-\(suffix)"
        self.subject = subject
        self.agent = agent
        self.checkoutPath = checkout
        worktreePath = URL(fileURLWithPath: root).appendingPathComponent(stem).path
        tmuxSessionName = "githubbar-\(agent.rawValue)-\(stem)"
        self.agentExecutablePath = agentExecutablePath
        self.id = id
    }

    public var gitFetchArguments: [String] {
        ["-C", checkoutPath, "fetch", "origin",
         "refs/pull/\(subject.key.number)/head:refs/heads/\(branchName)"]
    }

    public var gitWorktreeArguments: [String] {
        ["-C", checkoutPath, "worktree", "add", worktreePath, branchName]
    }

    public var tmuxArguments: [String] {
        ["new-session", "-d", "-s", tmuxSessionName, "-c", worktreePath,
         "exec \(Self.shellQuote(agentExecutablePath))"]
    }

    private var branchName: String {
        "githubbar/pr-\(subject.key.number)-\(id.uuidString.lowercased())"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
