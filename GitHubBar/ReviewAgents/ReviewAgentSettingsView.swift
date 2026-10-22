import GitHubBarCore
import SwiftUI

struct ReviewAgentSettingsView: View {
    @Bindable var model: ReviewAgentModel
    @Bindable var workspace: WorkspaceModel

    init(model: ReviewAgentModel, workspace: WorkspaceModel) {
        self.model = model
        self.workspace = workspace
    }

    init(model: ReviewAgentModel, workspaceModel: WorkspaceModel) {
        self.init(model: model, workspace: workspaceModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review agent").font(.headline)
            Text("Use any worker that implements the GitHubBar review protocol. A general-purpose agent CLI needs a compatible adapter; executable validation does not prove review support.")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                TextField("Display name", text: $model.draft.displayName)
                Picker("Worker management", selection: $model.draft.mode) {
                    Text("External worker").tag(ReviewAgentConnection.Mode.external)
                    Text("Start from GitHubBar").tag(ReviewAgentConnection.Mode.managed)
                }
                if model.draft.mode == .managed {
                    TextField("Executable (absolute path)", text: $model.draft.executable)
                    Text("Arguments: JSON string array or one argument per line")
                        .font(.caption)
                    TextEditor(text: $model.argumentsText)
                        .font(.system(.caption, design: .monospaced)).frame(height: 70)
                        .accessibilityLabel("Worker arguments")
                    TextField("Working directory (absolute path)", text: $model.draft.workingDirectory)
                    Text("Arguments are passed literally. No shell, quoting, variable expansion, or automatic installation. Save first; Start uses the saved connection.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Start your compatible worker separately with the CLI and data directory below. GitHubBar does not start, stop, or monitor external processes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Priority authors (GitHub logins, one per line)").font(.caption)
                TextEditor(text: $model.priorityAuthorsText).frame(height: 55)
                    .accessibilityLabel("Priority authors")
                Text("Empty by default. Listed authors receive medium priority; manual and sole-reviewer priority take precedence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.isLoaded || model.isBusy || model.isRunning)
            HStack {
                Button("Save") {
                    Task { if await model.save() { await workspace.reload() } }
                }.disabled(!model.isLoaded || model.isBusy || model.isRunning)
                Button("Test configuration") { Task { await model.test() } }
                    .disabled(!model.isLoaded || model.isBusy)
                Button("Start") { Task { await model.start() } }
                    .disabled(model.isBusy || model.isRunning || model.savedConnection?.mode != .managed)
                Button("Stop") { Task { await model.stop() } }
                    .disabled(!model.isRunning)
                if !model.isLoaded {
                    Button("Retry loading") { Task { await model.load() } }.disabled(model.isBusy)
                }
            }
            Text(model.status).font(.caption)
            if let message = model.testMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Bridge paths and lifecycle events") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GITHUBBAR_WORKSPACE_CLI").font(.caption.bold())
                    Text(model.workspaceCLI?.path ?? "Bundled CLI not found")
                    Text("GITHUBBAR_WORKSPACE_DIR").font(.caption.bold())
                    Text(model.dataDirectory)
                    Text("Worker stdout and stderr are discarded. Only the latest 50 lifecycle events are kept in memory.")
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in Text(event) }
                }.font(.caption).textSelection(.enabled)
            }
            WorkspaceAgentReviewView(workspace: workspace, subject: nil, pullRequest: nil)
        }
        .task {
            await model.load()
            while !Task.isCancelled {
                await model.refreshStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: workspace.monitoredAccountLogin) {
            await model.updateMonitoredAccount(workspace.monitoredAccountLogin)
        }
        .onChange(of: workspace.reviewDocument.enabled) { _, enabled in
            if !enabled { Task { await model.stop() } }
        }
    }
}
