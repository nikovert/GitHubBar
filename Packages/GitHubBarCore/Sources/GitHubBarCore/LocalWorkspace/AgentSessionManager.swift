import Foundation

public actor AgentSessionManager {
    private let store: LocalWorkspaceStore
    private let commandRunner: any CommandRunning
    private let gitURL: URL
    private let tmuxURL: URL?
    private let agentURLs: [AgentKind: URL]

    public init(
        store: LocalWorkspaceStore,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        tmuxURL: URL? = AgentSessionManager.findExecutable("tmux"),
        agentURLs: [AgentKind: URL] = [:]
    ) {
        self.store = store
        self.commandRunner = commandRunner
        self.gitURL = gitURL
        self.tmuxURL = tmuxURL
        self.agentURLs = agentURLs
    }

    public func launch(subject: BoardSubject, agent: AgentKind) async throws -> AgentSessionLink {
        let document = try await store.load()
        let configuration = document.configuration
        guard let checkoutPath = configuration.repositoryCheckouts[subject.key.repositoryNameWithOwner],
              FileManager.default.fileExists(atPath: checkoutPath) else {
            throw AgentSessionLaunchError.missingCheckout
        }
        guard let tmuxURL else { throw AgentSessionLaunchError.missingExecutable("tmux") }
        let command = agent == .codex ? configuration.codexCommand : configuration.claudeCommand
        guard let agentURL = agentURLs[agent] ?? Self.findExecutable(command) else {
            throw AgentSessionLaunchError.missingExecutable(command)
        }
        let plan = try AgentSessionLaunchPlan(
            subject: subject, agent: agent, checkoutPath: checkoutPath,
            worktreeRoot: configuration.worktreeRoot,
            agentExecutablePath: agentURL.path
        )
        try FileManager.default.createDirectory(
            atPath: configuration.worktreeRoot,
            withIntermediateDirectories: true
        )
        try await run(gitURL, arguments: plan.gitFetchArguments)
        try await run(gitURL, arguments: plan.gitWorktreeArguments)
        var session = AgentSessionLink(
            id: plan.id, subject: subject, agent: agent,
            worktreePath: plan.worktreePath, tmuxSessionName: plan.tmuxSessionName,
            managedWorktree: true, state: .stopped
        )
        let stoppedSession = session
        try await store.update { $0.setSession(stoppedSession) }
        do {
            try await run(tmuxURL, arguments: plan.tmuxArguments)
            session.state = .running
            session.lastSeenAt = .now
            let runningSession = session
            try await store.update { $0.setSession(runningSession) }
            return runningSession
        } catch {
            session.state = .failed
            let failedSession = session
            _ = try? await store.update { $0.setSession(failedSession) }
            throw error
        }
    }

    public func pinExisting(
        subject: BoardSubject,
        agent: AgentKind,
        worktreePath: String,
        tmuxSessionName: String?
    ) async throws -> AgentSessionLink {
        guard worktreePath.hasPrefix("/"), FileManager.default.fileExists(atPath: worktreePath) else {
            throw AgentSessionLaunchError.invalidPath
        }
        let session = AgentSessionLink(
            subject: subject, agent: agent,
            worktreePath: URL(fileURLWithPath: worktreePath).standardizedFileURL.path,
            tmuxSessionName: tmuxSessionName, managedWorktree: false,
            state: tmuxSessionName == nil ? .stopped : .running
        )
        try await store.update { $0.setSession(session) }
        return session
    }

    public func stop(id: UUID) async throws {
        let session = try await storedSession(id: id)
        if let name = session.tmuxSessionName, let tmuxURL {
            let exists = await commandRunner.run(
                executableURL: tmuxURL, arguments: ["has-session", "-t", name], environment: [:]
            )
            if exists.exitCode == 0 {
                try await run(tmuxURL, arguments: ["kill-session", "-t", name])
            }
        }
        try await store.update { document in
            guard let index = document.sessions.firstIndex(where: { $0.id == id }) else { return }
            document.sessions[index].state = .stopped
        }
    }

    public func restart(id: UUID) async throws -> AgentSessionLink {
        let session = try await storedSession(id: id)
        guard let name = session.tmuxSessionName, let tmuxURL else {
            throw AgentSessionLaunchError.missingExecutable("tmux")
        }
        guard FileManager.default.fileExists(atPath: session.worktreePath) else {
            throw AgentSessionLaunchError.invalidPath
        }
        let document = try await store.load()
        let command = session.agent == .codex
            ? document.configuration.codexCommand : document.configuration.claudeCommand
        guard let agentURL = agentURLs[session.agent] ?? Self.findExecutable(command) else {
            throw AgentSessionLaunchError.missingExecutable(command)
        }
        let exists = await commandRunner.run(
            executableURL: tmuxURL, arguments: ["has-session", "-t", name], environment: [:]
        )
        if exists.exitCode != 0 {
            let script = "exec \(Self.shellQuote(agentURL.path))"
            try await run(tmuxURL, arguments: [
                "new-session", "-d", "-s", name, "-c", session.worktreePath, script,
            ])
        }
        var running = session
        running.state = .running
        running.lastSeenAt = .now
        let runningSession = running
        try await store.update { $0.setSession(runningSession) }
        return running
    }

    public func refreshStates() async throws -> [AgentSessionLink] {
        let document = try await store.load()
        guard let tmuxURL else { return document.sessions }
        var sessions = document.sessions
        for index in sessions.indices {
            guard let name = sessions[index].tmuxSessionName else { continue }
            let result = await commandRunner.run(
                executableURL: tmuxURL, arguments: ["has-session", "-t", name], environment: [:]
            )
            let liveState: AgentSessionState = result.exitCode == 0 ? .running : .stopped
            if sessions[index].state != liveState {
                sessions[index].state = liveState
                if liveState == .running { sessions[index].lastSeenAt = .now }
            }
        }
        let refreshed = sessions
        if refreshed != document.sessions {
            try await store.update { latest in
                for session in refreshed {
                    guard let index = latest.sessions.firstIndex(where: { $0.id == session.id }) else {
                        continue
                    }
                    latest.sessions[index].state = session.state
                    latest.sessions[index].lastSeenAt = session.lastSeenAt
                }
            }
        }
        return refreshed
    }

    public func unlink(id: UUID) async throws {
        try await store.update { $0.removeSession(id: id) }
    }

    public func removeManagedWorktree(id: UUID) async throws {
        let document = try await store.load()
        guard let session = document.sessions.first(where: { $0.id == id }),
              session.managedWorktree else { throw AgentSessionLaunchError.unmanagedWorktree }
        let root = URL(fileURLWithPath: document.configuration.worktreeRoot).standardizedFileURL.path
        let path = URL(fileURLWithPath: session.worktreePath).standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { throw AgentSessionLaunchError.unmanagedWorktree }
        let status = await commandRunner.run(
            executableURL: gitURL,
            arguments: ["-C", path, "status", "--porcelain", "--ignored"], environment: [:]
        )
        guard status.exitCode == 0 else { throw AgentSessionLaunchError.commandFailed(status.standardError) }
        guard status.standardOutput.isEmpty else { throw AgentSessionLaunchError.dirtyWorktree }
        try await stop(id: id)
        try await run(gitURL, arguments: ["-C", path, "worktree", "remove", path])
        try await unlink(id: id)
    }

    private func storedSession(id: UUID) async throws -> AgentSessionLink {
        guard let session = try await store.load().sessions.first(where: { $0.id == id }) else {
            throw AgentSessionLaunchError.commandFailed("Pinned session no longer exists")
        }
        return session
    }

    private func run(_ executableURL: URL, arguments: [String]) async throws {
        let result = await commandRunner.run(
            executableURL: executableURL, arguments: arguments, environment: [:]
        )
        guard result.exitCode == 0 else {
            throw AgentSessionLaunchError.commandFailed(
                result.standardError.isEmpty ? "Command failed: \(executableURL.lastPathComponent)" : result.standardError
            )
        }
    }

    public static func findExecutable(_ name: String) -> URL? {
        let paths: [String]
        if name.hasPrefix("/") {
            paths = [name]
        } else {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
                + path.split(separator: ":").map(String.init)
            paths = directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
