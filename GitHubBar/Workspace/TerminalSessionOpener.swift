import AppKit
import GitHubBarCore

@MainActor
enum TerminalSessionOpener {
    enum Error: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }

    static func open(_ session: AgentSessionLink) throws {
        let command: String
        if let target = session.tmuxSessionTarget {
            guard let tmuxURL = AgentSessionManager.findExecutable("tmux") else {
                throw Error.failed("tmux is not installed")
            }
            command = "\(shellQuote(tmuxURL.path)) attach-session -t \(shellQuote(target))"
        } else {
            command = "cd \(shellQuote(session.worktreePath))"
        }
        let source = """
        tell application "Terminal"
            do script "\(appleScriptQuote(command))"
            activate
        end tell
        """
        var errorInfo: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&errorInfo) != nil else {
            throw Error.failed(errorInfo?.description ?? "Terminal automation failed")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
