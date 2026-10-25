import Foundation
import GitHubBarCore
import Observation

@MainActor
@Observable
final class WorktreeCleanupModel {
    enum Phase { case idle, scanning, choice, reviewing, running, results }
    private(set) var phase: Phase = .idle
    private(set) var candidates: [WorktreeCleanupCandidate] = []
    private(set) var results: [WorktreeCleanupResult] = []
    private(set) var selected: Set<String> = []
    private(set) var errorMessage: String?
    @ObservationIgnored private(set) var pendingTask: Task<Void, Never>?
    @ObservationIgnored var onCompletion: (() async -> Void)?
    @ObservationIgnored private let service: any WorktreeCleanupServicing
    @ObservationIgnored private var revision = 0
    private var accountLogin: String?
    private var configuration: WorkspaceConfiguration?
    var isBusy: Bool { phase == .scanning || phase == .running }
    var eligible: [WorktreeCleanupCandidate] { candidates.filter(\.isEligible) }
    init(service: any WorktreeCleanupServicing) { self.service = service }

    func updateAccount(_ login: String?) {
        guard accountLogin != login else { return }
        cancel()
        accountLogin = login
    }

    func updateConfiguration(_ configuration: WorkspaceConfiguration) {
        guard self.configuration != configuration else { return }
        if self.configuration != nil { cancel() }
        self.configuration = configuration
    }

    func scan() {
        guard !isBusy else { return }
        guard let accountLogin, !accountLogin.isEmpty else {
            errorMessage = "Connect a monitored GitHub account before scanning."
            return
        }
        revision += 1
        let version = revision
        candidates = []; results = []; selected = []; errorMessage = nil
        phase = .scanning
        pendingTask = Task { [weak self, service] in
            do {
                let rows = try await service.preview(accountLogin: accountLogin)
                guard let self, version == revision, !Task.isCancelled else { return }
                candidates = rows
                phase = .choice
            } catch {
                guard let self, version == revision else { return }
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    func reviewIndividually() {
        guard phase == .choice else { return }
        selected = []
        phase = .reviewing
    }

    func select(_ id: String, enabled: Bool) {
        guard phase == .reviewing, eligible.contains(where: { $0.id == id }) else { return }
        if enabled { selected.insert(id) } else { selected.remove(id) }
    }

    func confirmAll() {
        guard phase == .choice else { return }
        execute(eligible)
    }

    func confirmSelected() {
        guard phase == .reviewing else { return }
        execute(eligible.filter { selected.contains($0.id) })
    }

    private func execute(_ approved: [WorktreeCleanupCandidate]) {
        guard !isBusy, !approved.isEmpty, let accountLogin else { return }
        let version = revision
        phase = .running
        pendingTask = Task { [weak self, service] in
            let outcomes = await service.execute(approved, accountLogin: accountLogin)
            guard let self else { return }
            await onCompletion?()
            guard version == revision else { return }
            results = outcomes
            if Task.isCancelled {
                errorMessage = "Cleanup stopped. Completed removals are not undone; remaining worktrees are retained."
            }
            selected = []
            phase = .results
        }
    }

    func cancel() {
        revision += 1
        pendingTask?.cancel()
        candidates = []; selected = []; results = []
        phase = .idle
        errorMessage = nil
    }

    func stopAfterCurrent() { pendingTask?.cancel() }
}
