import AppKit
import GitHubBarCore
import Observation

@MainActor
@Observable
final class WorkspaceModel {
    private(set) var document: LocalWorkspaceDocument = .empty
    var selectedSubject: BoardSubject?
    var errorMessage: String?

    @ObservationIgnored private let store: LocalWorkspaceStore
    @ObservationIgnored private let sessions: AgentSessionManager
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored var onDocumentChange: (() -> Void)?

    init(store: LocalWorkspaceStore, sessions: AgentSessionManager) {
        self.store = store
        self.sessions = sessions
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
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the local workspace: \(error.localizedDescription)"
        }
    }

    func setPriority(_ priority: BoardPriority, for subject: BoardSubject) {
        updateEntry(subject) { $0.priority = priority }
    }

    func setTag(_ id: String, enabled: Bool, currentIDs: Set<String>, for subject: BoardSubject) {
        updateEntry(subject) { entry in
            var tags = entry.tagIDs ?? currentIDs
            if enabled { tags.insert(id) } else { tags.remove(id) }
            entry.tagIDs = tags
        }
    }

    func setNote(_ note: String, for subject: BoardSubject) {
        updateEntry(subject) { $0.note = note }
    }

    private func updateEntry(
        _ subject: BoardSubject,
        edit: @escaping @Sendable (inout BoardEntry) -> Void
    ) {
        perform { [store] in
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
        perform { [store] in
            _ = try await store.update { $0.configuration.repositoryCheckouts[repository] = path }
        }
    }

    func saveWorktreeRoot(_ path: String) {
        perform { [store] in
            _ = try await store.update { $0.configuration.worktreeRoot = path }
        }
    }

    func saveTag(_ tag: BoardTag) {
        perform { [store] in _ = try await store.update { $0.setTag(tag) } }
    }

    func createTag(name: String, color: BoardTagColor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = BoardTag(id: "custom-\(UUID().uuidString.lowercased())", name: trimmed, color: color)
        saveTag(tag)
    }

    func launch(_ agent: AgentKind, for subject: BoardSubject) {
        perform { [sessions] in _ = try await sessions.launch(subject: subject, agent: agent) }
    }

    func pin(_ agent: AgentKind, for subject: BoardSubject, path: String, tmuxName: String?) {
        perform { [sessions] in
            _ = try await sessions.pinExisting(
                subject: subject, agent: agent, worktreePath: path,
                tmuxSessionName: tmuxName?.isEmpty == true ? nil : tmuxName
            )
        }
    }

    func stopSession(_ id: UUID) {
        perform { [sessions] in try await sessions.stop(id: id) }
    }

    func restartSession(_ id: UUID) {
        perform { [sessions] in _ = try await sessions.restart(id: id) }
    }

    func unlinkSession(_ id: UUID) {
        perform { [sessions] in try await sessions.unlink(id: id) }
    }

    func removeWorktree(_ id: UUID) {
        perform { [sessions] in try await sessions.removeManagedWorktree(id: id) }
    }

    func focus(_ session: AgentSessionLink) {
        do {
            try TerminalSessionOpener.open(session)
        } catch {
            errorMessage = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await operation()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
