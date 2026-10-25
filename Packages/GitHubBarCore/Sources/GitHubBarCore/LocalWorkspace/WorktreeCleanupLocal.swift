import Foundation
import Darwin

struct WorktreeCleanupLocal: Sendable {
    let runner: any CommandRunning
    let tmuxURL: URL?
    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func validate(path: String, links: [AgentSessionLink], configuration: WorkspaceConfiguration) async throws {
        guard !links.isEmpty, links.allSatisfy(\.managedWorktree), path.hasPrefix("/"),
              !path.contains("\n"), !path.contains("\t"),
              FileManager.default.fileExists(atPath: path) else {
            throw CleanupBlocked("Only existing GitHubBar-managed worktrees can be cleaned up.")
        }
        let root = Self.canonical(configuration.worktreeRoot)
        let lexicalRoot = URL(fileURLWithPath: configuration.worktreeRoot).standardizedFileURL.path
        guard configuration.worktreeRoot.hasPrefix("/"), root != "/", path.hasPrefix(root + "/"),
              links.allSatisfy({ link in
                  let lexical = URL(fileURLWithPath: link.worktreePath).standardizedFileURL.path
                  return lexical.hasPrefix(lexicalRoot + "/") &&
                      root + lexical.dropFirst(lexicalRoot.count) == Self.canonical(link.worktreePath)
              }) else {
            throw CleanupBlocked("The path is outside the managed root or contains a symlink.")
        }
        let checkout = try checkout(configuration: configuration, links: links)
        let topLevel = try await git(["rev-parse", "--show-toplevel"], at: path).trimmed
        guard path != Self.canonical(checkout), topLevel == path else {
            throw CleanupBlocked("The main checkout or an unexpected repository cannot be removed.")
        }
        let records = try await git(["worktree", "list", "--porcelain", "-z"], at: checkout)
            .components(separatedBy: "\0\0").map { $0.components(separatedBy: "\0") }
        guard records.first?.first != "worktree " + path,
              let record = records.first(where: { $0.first == "worktree " + path }),
              !record.contains(where: { $0.hasPrefix("locked") || $0.hasPrefix("prunable") || $0 == "bare" }) else {
            throw CleanupBlocked("Worktree registration is missing, locked, or is the main checkout.")
        }
        let common = try await git(["rev-parse", "--git-common-dir"], at: path).trimmed
        let checkoutCommon = try await git(["rev-parse", "--git-common-dir"], at: checkout).trimmed
        func absolute(_ value: String, from base: String) -> String {
            Self.canonical(value.hasPrefix("/") ? value : base + "/" + value)
        }
        guard absolute(common, from: path) == absolute(checkoutCommon, from: checkout) else {
            throw CleanupBlocked("Worktree belongs to a different repository.")
        }
        let origin = try await git(["remote", "get-url", "origin"], at: path)
        guard let repository = AgentSessionManager.repositoryNameWithOwner(fromRemoteURL: origin),
              links.allSatisfy({ $0.subject.key.repositoryNameWithOwner == repository }) else {
            throw CleanupBlocked("Origin does not match the linked PR repository.")
        }
        let status = try await git(["status", "--porcelain", "--ignored", "--untracked-files=all"], at: path)
        guard status.isEmpty else { throw CleanupBlocked("Local changes, untracked, or ignored files must be preserved.") }
        let tracked = try await git(["ls-files", "-v", "-z"], at: path)
        guard !tracked.split(separator: "\0").contains(where: {
            guard let first = $0.first else { return false }
            return first == "S" || first.isLowercase
        }) else { throw CleanupBlocked("Hidden or sparse tracked files prevent a reliable clean check.") }
    }

    func verifyOriginHead(path: String, subject: BoardSubject, sha: String) async throws {
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { throw CleanupBlocked("GitHub did not return a valid PR head.") }
        let ref = "refs/githubbar/cleanup/" + UUID().uuidString.lowercased()
        let result = await command(["fetch", "--no-tags", "--no-write-fetch-head", "origin",
            "refs/pull/\(subject.key.number)/head:\(ref)"], at: path)
        guard result.exitCode == 0 else { throw CleanupBlocked("Could not fetch the PR head from origin. Nothing was removed.") }
        let fetched: String
        do { fetched = try await git(["rev-parse", "--verify", ref], at: path).trimmed }
        catch { throw CleanupBlocked("Could not verify fetched PR head.") }
        let deleted = await command(["update-ref", "-d", ref, fetched], at: path)
        guard deleted.exitCode == 0 else { throw CleanupBlocked("Could not release the temporary verification ref.") }
        guard fetched == sha else { throw CleanupBlocked("GitHub and origin disagree about the PR head. Scan again.") }
        try await requireHead(sha, path: path)
    }

    func requireHead(_ sha: String, path: String) async throws {
        guard try await git(["rev-parse", "HEAD"], at: path).trimmed == sha else {
            throw CleanupBlocked("Local HEAD differs from the merged PR head; local commits are preserved.")
        }
    }

    func liveSessions(path: String, links: [AgentSessionLink]) async throws -> [String: String] {
        guard let tmuxURL else { throw CleanupBlocked("Install tmux to verify session activity before cleanup.") }
        let response = await runner.run(executableURL: tmuxURL,
            arguments: ["list-panes", "-a", "-F", "#{session_id}\t#{session_name}\t#{pane_current_path}"], environment: [:])
        if response.exitCode != 0 {
            if response.exitCode == 1 && (response.standardError.contains("no server running") ||
                (response.standardError.contains("error connecting to") && response.standardError.contains("No such file or directory"))) {
                return [:]
            }
            throw CleanupBlocked("Could not verify tmux session activity.")
        }
        var result: [String: String] = [:]
        let names = Set(links.compactMap(\.tmuxSessionName))
        for line in response.standardOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[0].first == "$", fields[0].dropFirst().allSatisfy(\.isNumber) else {
                throw CleanupBlocked("Unrecognized tmux session metadata.")
            }
            let cwd = Self.canonical(fields[2])
            if names.contains(fields[1]) {
                guard links.filter({ $0.tmuxSessionName == fields[1] }).allSatisfy({ link in
                    let expected = "githubbar-\(link.agent.rawValue)-\(link.subject.key.repository)-pr-\(link.subject.key.number)-\(link.id.uuidString.prefix(8).lowercased())"
                    return link.managedWorktree && expected == fields[1]
                }), cwd == path || cwd.hasPrefix(path + "/") else {
                    throw CleanupBlocked("A linked session's ownership or working directory could not be verified.")
                }
                result[fields[1]] = fields[0]
            } else if cwd == path || cwd.hasPrefix(path + "/") {
                throw CleanupBlocked("An unlinked terminal session is using this worktree; close it manually first.")
            }
        }
        return result
    }

    func stop(sessionID: String) async throws {
        guard let tmuxURL else { throw CleanupBlocked("tmux is unavailable.") }
        let r = await runner.run(executableURL: tmuxURL, arguments: ["kill-session", "-t", sessionID], environment: [:])
        guard r.exitCode == 0 else { throw CleanupBlocked("Could not stop the selected session. Worktree retained.") }
    }

    func requireNoLocalProcesses(path: String) async throws {
        let result = await runner.run(executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-u", String(getuid()), "-d", "cwd", "-Fpn"], environment: [:])
        guard (result.exitCode == 0 || result.exitCode == 1), result.standardError.isEmpty else {
            throw CleanupBlocked("Could not verify remaining local processes. Worktree retained.")
        }
        for field in result.standardOutput.split(separator: "\n") where field.hasPrefix("n") {
            let cwd = Self.canonical(String(field.dropFirst()))
            if cwd == path || cwd.hasPrefix(path + "/") {
                throw CleanupBlocked("A local process still uses this worktree. Close it and scan again.")
            }
        }
    }

    func remove(path: String, configuration: WorkspaceConfiguration, links: [AgentSessionLink]) async throws {
        let checkout = try checkout(configuration: configuration, links: links)
        _ = try await git(["worktree", "remove", "--", path], at: checkout)
    }

    private func checkout(configuration: WorkspaceConfiguration, links: [AgentSessionLink]) throws -> String {
        guard let key = links.first?.subject.key.repositoryNameWithOwner,
              let checkout = configuration.repositoryCheckouts[key], checkout.hasPrefix("/") else {
            throw CleanupBlocked("Configure the repository checkout before cleanup.")
        }
        return Self.canonical(checkout)
    }

    private func command(_ args: [String], at path: String) async -> CommandResult {
        await runner.run(executableURL: gitURL,
            arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", path] + args,
            environment: ["GIT_TERMINAL_PROMPT": "0"])
    }

    private func git(_ args: [String], at path: String) async throws -> String {
        let r = await command(args, at: path)
        guard r.exitCode == 0 else { throw CleanupBlocked("Git could not verify or remove this worktree (\(args.first ?? "operation")).") }
        return r.standardOutput
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
