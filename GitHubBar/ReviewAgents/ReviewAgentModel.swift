import Foundation
import GitHubBarCore
import Observation

@MainActor
@Observable
final class ReviewAgentModel {
    var draft = ReviewAgentConnection()
    var argumentsText = "[]"
    var priorityAuthorsText = ""
    private(set) var processState: ReviewAgentProcessSnapshot.State = .stopped
    private(set) var events: [String] = []
    private(set) var isBusy = false
    private(set) var isLoaded = false
    private(set) var savedConnection: ReviewAgentConnection?
    private(set) var errorMessage: String?
    private(set) var testMessage: String?
    private(set) var monitoredAccountLogin: String?

    @ObservationIgnored private let store: AgentReviewStore
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let launcher = ReviewAgentLauncher()
    @ObservationIgnored private var lifecycleVersion = 0

    init(store: AgentReviewStore, bundleURL: URL = Bundle.main.bundleURL) {
        self.store = store
        self.bundleURL = bundleURL
    }

    convenience init(directoryURL: URL? = nil, bundleURL: URL = Bundle.main.bundleURL) {
        self.init(store: AgentReviewStore(directoryURL: directoryURL), bundleURL: bundleURL)
    }

    var dataDirectory: String { store.directoryURL.path }
    var workspaceCLI: URL? { WorkspaceCLIExecutableLocator.locate(bundleURL: bundleURL) }
    var isRunning: Bool { processState == .running || processState == .stopping }
    var status: String {
        switch processState {
        case .running: "Process running; compatibility unverified"
        case .stopping: "Stopping process…"
        case let .exited(code): "Process exited (\(code))"
        case .stopped: savedConnection?.mode == .external
            ? "External worker; status is not monitored" : "Process stopped"
        }
    }

    func load() async {
        guard !isLoaded, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let document = try await store.load()
            savedConnection = document.reviewAgentConnection
            draft = savedConnection ?? ReviewAgentConnection()
            argumentsText = String(decoding: try JSONEncoder().encode(draft.arguments), as: UTF8.self)
            priorityAuthorsText = document.priorityAuthors.joined(separator: "\n")
            isLoaded = true
            errorMessage = nil
        } catch { report(error) }
    }

    @discardableResult
    func save() async -> Bool {
        guard isLoaded, !isBusy, !isRunning else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let connection = try configuredDraft()
            let authors = priorityAuthorsText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let document = try await store.saveConnection(connection, priorityAuthors: authors)
            savedConnection = document.reviewAgentConnection
            draft = connection
            priorityAuthorsText = document.priorityAuthors.joined(separator: "\n")
            errorMessage = nil
            testMessage = "Settings saved. Worker has not been started."
            return true
        } catch { report(error); return false }
    }

    /// Checks the draft locally without launching an executable or claiming protocol support.
    func test() async {
        guard !isBusy else { return }
        do {
            _ = try configuredDraft()
            guard workspaceCLI != nil else {
                throw AgentReviewError.invalid("The bundled workspace CLI is missing. Rebuild or reinstall GitHubBar.")
            }
            errorMessage = nil
            testMessage = "Configuration and bundled CLI are valid. Worker compatibility has not been tested. Nothing was started or saved."
        } catch { report(error) }
    }

    func start() async {
        guard !isBusy, !isRunning else { return }
        isBusy = true
        let version = lifecycleVersion
        defer { isBusy = false }
        do {
            let document = try await store.load()
            guard version == lifecycleVersion else { return }
            guard document.enabled, let login = monitoredAccountLogin,
                  !login.isEmpty, login.lowercased() == document.accountLogin.lowercased() else {
                throw AgentReviewError.invalid("Enable reviews for the matching monitored account before starting a worker.")
            }
            guard let connection = document.reviewAgentConnection else {
                throw AgentReviewError.invalid("Save a compatible worker connection first.")
            }
            guard let cli = workspaceCLI else {
                throw AgentReviewError.invalid("The bundled workspace CLI is missing. Rebuild or reinstall GitHubBar.")
            }
            try await launcher.start(connection: connection, workspaceCLI: cli, directoryURL: store.directoryURL)
            if version != lifecycleVersion { await launcher.stop() }
            await refreshStatus()
            errorMessage = nil
            testMessage = nil
        } catch { report(error) }
    }

    func stop() async {
        lifecycleVersion += 1
        await launcher.stop()
        await refreshStatus()
    }

    func updateMonitoredAccount(_ login: String?) async {
        guard login?.lowercased() != monitoredAccountLogin?.lowercased() else { return }
        monitoredAccountLogin = login
        await stop()
    }

    func refreshStatus() async {
        let snapshot = await launcher.snapshot()
        processState = snapshot.state
        events = snapshot.events
    }

    private func configuredDraft() throws -> ReviewAgentConnection {
        var connection = draft
        connection.arguments = try ReviewAgentConnection.parseArguments(argumentsText)
        return try connection.validated()
    }

    private func report(_ error: any Error) {
        testMessage = nil
        errorMessage = (error as? AgentReviewError)?.errorDescription
            ?? "Could not access review settings. Check workspace file permissions and try again."
    }
}
