import GitHubBarCore
import SwiftUI

struct ReviewChatPanel: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var workspace: WorkspaceModel
    let pullRequest: PullRequestPresentation?
    @Binding var showsSettings: Bool
    @AppStorage("githubbar.chat.configuration") private var configurationData = Data()

    private var configuration: ReviewChatConfiguration {
        (try? JSONDecoder().decode(ReviewChatConfiguration.self, from: configurationData)) ?? ReviewChatConfiguration()
    }
    private var configured: Bool { (try? configuration.validated()) != nil }
    private var policy: String {
        guard let pullRequest else { return "Advisory chat only. Do not modify files, publish comments, or reply on GitHub." }
        let value = workspace.reviewDocument.effectivePolicy(for: workspace.reviewContext(for: pullRequest))
        return "Advisory chat only. Do not modify files or publish anything. Separate review-worker policy: fixes=\(value.fixMode?.rawValue ?? "off"), comments=\(value.comments ?? false), replies=\(value.replies ?? false). This does not grant chat permission to act."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text(configuration.displayName.nilIfEmpty ?? "Ask an agent").font(.headline)
                Spacer()
                Button { showsSettings = true } label: { Image(systemName: "gearshape") }.help("Configure chat agent")
            }
            HStack(spacing: 6) {
                Circle().fill(review.chatting ? Color.orange : configured ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(review.chatting ? "Working…" : configured ? "Configured · available on request" : "Chat not configured")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let snapshot = review.snapshot {
                Text("Context: #\(snapshot.key.number) · \(snapshot.headSHA.prefix(8))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let selected = review.selection {
                    Text("\(selected.path):\(selected.line)").font(.caption.monospaced()).lineLimit(2)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if review.draft.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Understand the change before you decide.").font(.subheadline.weight(.medium))
                                Text("Ask about risks, tests, or a selected line. The agent receives this PR's description and available diff context.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(["Summarize this PR and its main risks.", "Which tests are missing?", "What should I check before approving?"], id: \.self) { prompt in
                                    Button(prompt) { review.question = prompt }.buttonStyle(.plain).foregroundStyle(.blue)
                                        .font(.caption).padding(.vertical, 3)
                                }
                            }.padding(.vertical, 12)
                        }
                        ForEach(review.draft.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : configuration.displayName.nilIfEmpty ?? "Agent")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                                Text(message.text).font(.subheadline).textSelection(.enabled)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == "user" ? Color(nsColor: .windowBackgroundColor) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                                .id(message.id)
                        }
                        ForEach(Array(review.citations.enumerated()), id: \.offset) { _, citation in
                            Button("\(citation.path):\(citation.line)") { review.follow(citation) }
                                .font(.caption.monospaced()).buttonStyle(.link)
                        }
                    }
                }
                .onChange(of: review.draft.messages.count) { _, _ in
                    if let last = review.draft.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if !configured {
                Button("Connect a chat adapter…") { showsSettings = true }
            }
            TextField("Ask about this PR…", text: $review.question, axis: .vertical)
                .lineLimit(3...7).textFieldStyle(.roundedBorder)
            HStack {
                if review.chatting { Button("Stop") { review.stopChat() } }
                Spacer()
                Button("Ask agent") { review.sendQuestion(configuration: configuration, policy: policy) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!configured || review.chatting || review.snapshot == nil || !review.local.canSave || review.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Answers stay here. GitHub reviews are submitted separately.").font(.caption2).foregroundStyle(.secondary)
            Divider()
            if let subject = workspace.selectedSubject {
                DisclosureGroup("Review-agent permissions") {
                    WorkspaceReviewPolicyControls(workspace: workspace, subject: subject).padding(.top, 6)
                }.font(.caption)
                let sessions = workspace.document.sessions(for: subject)
                ForEach(sessions) { session in
                    Button("Jump to \(session.agent.rawValue.capitalized) session") { workspace.focus(session) }
                        .font(.caption)
                }
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ReviewChatSettingsView: View {
    @AppStorage("githubbar.chat.configuration") private var configurationData = Data()
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var directory = ""
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a chat agent").font(.title2.bold())
            Text("Use a local command that supports GitHubBar's JSON chat protocol. Chat is separate from the background review queue.")
                .foregroundStyle(.secondary)
            Menu("Use an installed CLI…") {
                Button("Codex") { useInstalledCLI("codex") }
                Button("Claude") { useInstalledCLI("claude") }
            }
            Form {
                TextField("Display name", text: $name)
                TextField("Executable (absolute path)", text: $executable)
                TextField("Working directory", text: $directory)
                TextField("Arguments (JSON array or one per line)", text: $arguments, axis: .vertical).lineLimit(3...6)
            }
            Text("The adapter receives PR context and returns an answer with optional citations. CLI presets use your existing local login. You can also configure any compatible JSON adapter.")
                .font(.caption).foregroundStyle(.secondary)
            if let guide = Bundle.main.url(forResource: "agent-chat", withExtension: "md") {
                Button("Open chat setup guide") { NSWorkspace.shared.open(guide) }
            }
            if let status { Text(status).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !configurationData.isEmpty {
                    Button("Disconnect") { configurationData = Data(); dismiss() }
                }
                Button("Check paths") {
                    do { _ = try makeConfiguration(); status = "Paths are valid. This does not start the agent or verify protocol support." }
                    catch { status = error.localizedDescription }
                }
                Spacer()
                Button("Save") {
                    do {
                        configurationData = try JSONEncoder().encode(makeConfiguration())
                        dismiss()
                    } catch { status = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 590)
        .onAppear {
            if let value = try? JSONDecoder().decode(ReviewChatConfiguration.self, from: configurationData) {
                name = value.displayName; executable = value.executable; directory = value.workingDirectory
                arguments = String(decoding: (try? JSONEncoder().encode(value.arguments)) ?? Data(), as: UTF8.self)
            }
        }
    }

    private func makeConfiguration() throws -> ReviewChatConfiguration {
        try ReviewChatConfiguration(displayName: name, executable: executable,
            arguments: ReviewAgentConnection.parseArguments(arguments), workingDirectory: directory).validated()
    }

    private func useInstalledCLI(_ provider: String) {
        guard let cli = AgentSessionManager.findExecutable(provider),
              let python = AgentSessionManager.findExecutable("python3"),
              let adapter = Bundle.main.url(forResource: "review-chat-adapter", withExtension: "py") else {
            status = "This preset requires the installed \(provider) CLI, Python 3, and GitHubBar's bundled adapter. Install and log into the CLI first, or configure a custom adapter."
            return
        }
        name = provider.capitalized
        executable = python.path
        directory = NSHomeDirectory()
        arguments = String(decoding: (try? JSONEncoder().encode([adapter.path, "--provider", provider, "--cli", cli.path])) ?? Data(), as: UTF8.self)
        status = "Preset loaded. Choose a working directory, then save. Questions use your existing CLI account."
    }
}
