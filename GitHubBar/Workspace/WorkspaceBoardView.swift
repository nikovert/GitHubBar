import AppKit
import GitHubBarCore
import SwiftUI

struct WorkspaceBoardView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var appModel: AppModel

    private var subjects: [BoardSubject] {
        let pullRequests = appModel.state.needsYourReview + appModel.state.authoredPullRequests
        var result = appModel.state.pullRequestStacks.compactMap { stack in
            stack.root.flatMap { try? PullRequestKey(url: $0.url) }.map(BoardSubject.stack)
        }
        result += pullRequests.compactMap { pullRequest in
            (try? PullRequestKey(url: pullRequest.url)).map(BoardSubject.pullRequest)
        }
        return Array(Set(result)).sorted { $0.key.description < $1.key.description }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $workspace.selectedSubject) {
                ForEach(subjects, id: \.self) { subject in
                    subjectRow(subject).tag(subject)
                }
            }
            .frame(minWidth: 260, idealWidth: 310)

            Divider()

            if let subject = workspace.selectedSubject {
                WorkspaceDetailView(
                    workspace: workspace,
                    subject: subject,
                    stackRoot: stackRoot(for: subject)
                )
                .id(subject)
            } else {
                ContentUnavailableView(
                    "Select a pull request",
                    systemImage: "tray.full",
                    description: Text("Choose a PR or stack to set local status and manage agents.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 590)
        .onAppear {
            if workspace.selectedSubject == nil { workspace.selectedSubject = subjects.first }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = workspace.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { workspace.errorMessage = nil }
                }
                .padding(10)
                .background(Color.red.opacity(0.13))
            }
        }
    }

    private func subjectRow(_ subject: BoardSubject) -> some View {
        let resolved = workspace.document.resolvedEntry(
            for: subject, stackRoot: stackRoot(for: subject)
        )
        return HStack(spacing: 6) {
            Image(systemName: subject.isStack ? "square.stack.3d.up" : "arrow.triangle.pull")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.key.description).lineLimit(1)
                Text(subject.isStack ? "Stack" : "Pull request")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if resolved.priority != .none {
                Text(resolved.priority.rawValue.capitalized)
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !workspace.document.sessions(for: subject).isEmpty {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }
    }

    private func stackRoot(for subject: BoardSubject) -> PullRequestKey? {
        guard case .pullRequest = subject else { return nil }
        return appModel.state.pullRequestStacks.first { stack in
            stack.pullRequests.contains { (try? PullRequestKey(url: $0.url)) == subject.key }
        }?.root.flatMap { try? PullRequestKey(url: $0.url) }
    }
}

private struct WorkspaceDetailView: View {
    @Bindable var workspace: WorkspaceModel
    let subject: BoardSubject
    let stackRoot: PullRequestKey?

    @State private var noteDraft = ""
    @State private var checkoutPath = ""
    @State private var worktreeRoot = ""
    @State private var pinPath = ""
    @State private var pinTmuxName = ""
    @State private var pinAgent: AgentKind = .codex
    @State private var customTagName = ""
    @State private var customTagColor: BoardTagColor = .blue
    @State private var worktreeToRemove: AgentSessionLink?

    private var resolved: ResolvedBoardEntry {
        workspace.document.resolvedEntry(for: subject, stackRoot: stackRoot)
    }

    private var relatedSessions: [AgentSessionLink] {
        let direct = workspace.document.sessions(for: subject)
        guard let stackRoot else { return direct }
        return direct + workspace.document.sessions(for: .stack(stackRoot))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject.key.description).font(.title2.bold())
                        Text(subject.isStack ? "Local stack board" : "Local pull-request board")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Open on GitHub ↗", destination: subject.key.url)
                }

                GroupBox("Priority and status") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Priority", selection: Binding(
                            get: { resolved.priority },
                            set: { workspace.setPriority($0, for: subject) }
                        )) {
                            ForEach(BoardPriority.allCases, id: \.self) { priority in
                                Text(priority.rawValue.capitalized).tag(priority)
                            }
                        }
                        .frame(maxWidth: 270)
                        FlowTagsView(workspace: workspace, subject: subject, selectedIDs: resolved.tagIDs)
                        if let origin = resolved.updatedBy {
                            Text("Last local update by \(origin)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }

                GroupBox("Agent notes") {
                    VStack(alignment: .leading) {
                        TextEditor(text: $noteDraft)
                            .font(.body)
                            .frame(minHeight: 85)
                            .scrollContentBackground(.hidden)
                        Button("Save note") { workspace.setNote(noteDraft, for: subject) }
                    }
                    .padding(5)
                }

                GroupBox("Pinned agent sessions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(relatedSessions) { session in
                            sessionRow(session)
                        }
                        if relatedSessions.isEmpty {
                            Text("No agent session pinned yet.")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("New Codex worktree") { workspace.launch(.codex, for: subject) }
                            Button("New Claude worktree") { workspace.launch(.claude, for: subject) }
                        }
                        Divider()
                        Text("Pin an existing worktree or tmux session")
                            .font(.subheadline.bold())
                        HStack {
                            Picker("Agent", selection: $pinAgent) {
                                ForEach(AgentKind.allCases, id: \.self) { agent in
                                    Text(agent.rawValue.capitalized).tag(agent)
                                }
                            }
                            .frame(width: 140)
                            TextField("Absolute worktree path", text: $pinPath)
                            TextField("tmux session (optional)", text: $pinTmuxName)
                        }
                        Button("Pin session") {
                            workspace.pin(pinAgent, for: subject, path: pinPath, tmuxName: pinTmuxName)
                        }
                        .disabled(pinPath.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }

                DisclosureGroup("Workspace setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local checkout for \(subject.key.repositoryNameWithOwner)")
                        HStack {
                            TextField("Absolute checkout path", text: $checkoutPath)
                            Button("Save checkout") {
                                workspace.saveCheckout(checkoutPath, for: subject.key.repositoryNameWithOwner)
                            }
                        }
                        Text("Root for new worktrees")
                        HStack {
                            TextField("Absolute worktree root", text: $worktreeRoot)
                            Button("Save root") { workspace.saveWorktreeRoot(worktreeRoot) }
                        }
                        Text("New worktrees fetch PR heads from the checkout's origin remote.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Manage status tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(workspace.document.tags) { tag in
                            TagEditorRow(tag: tag, onSave: workspace.saveTag)
                        }
                        HStack {
                            TextField("New tag", text: $customTagName)
                            Picker("Color", selection: $customTagColor) {
                                ForEach(BoardTagColor.allCases, id: \.self) { color in
                                    Text(color.rawValue.capitalized).tag(color)
                                }
                            }
                            Button("Add") {
                                workspace.createTag(name: customTagName, color: customTagColor)
                                customTagName = ""
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(22)
        }
        .onAppear(perform: loadDrafts)
        .onChange(of: resolved.note) { previous, updated in
            if noteDraft == previous { noteDraft = updated }
        }
        .confirmationDialog(
            "Remove this managed worktree?",
            isPresented: Binding(
                get: { worktreeToRemove != nil },
                set: { if !$0 { worktreeToRemove = nil } }
            )
        ) {
            Button("Remove clean worktree", role: .destructive) {
                if let session = worktreeToRemove { workspace.removeWorktree(session.id) }
                worktreeToRemove = nil
            }
        } message: {
            Text("GitHubBar will refuse if the worktree has uncommitted changes. This cannot be undone here.")
        }
    }

    private func sessionRow(_ session: AgentSessionLink) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "terminal")
                Text(session.agent.rawValue.capitalized).bold()
                Text(session.state.rawValue.capitalized)
                    .foregroundStyle(session.state == .running ? .green : .secondary)
                Spacer()
                Button("Jump to session") { workspace.focus(session) }
                    .disabled(session.state != .running && session.tmuxSessionName != nil)
                Button("Stop") { workspace.stopSession(session.id) }
                    .disabled(session.state != .running)
                Button("Restart") { workspace.restartSession(session.id) }
                    .disabled(session.tmuxSessionName == nil)
                Menu {
                    Button("Unpin") { workspace.unlinkSession(session.id) }
                    if session.managedWorktree {
                        Button("Remove worktree…") { worktreeToRemove = session }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            Text(session.worktreePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let name = session.tmuxSessionName {
                Text("tmux: \(name)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadDrafts() {
        noteDraft = resolved.note
        checkoutPath = workspace.document.configuration.repositoryCheckouts[
            subject.key.repositoryNameWithOwner
        ] ?? ""
        worktreeRoot = workspace.document.configuration.worktreeRoot
    }
}

private struct FlowTagsView: View {
    @Bindable var workspace: WorkspaceModel
    let subject: BoardSubject
    let selectedIDs: Set<String>

    var body: some View {
        HStack(spacing: 5) {
            ForEach(workspace.document.tags.filter { !$0.isArchived }) { tag in
                let selected = selectedIDs.contains(tag.id)
                Button {
                    workspace.setTag(
                        tag.id, enabled: !selected, currentIDs: selectedIDs, for: subject
                    )
                } label: {
                    Text(tag.name)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(tag.color.swiftUIColor.opacity(selected ? 0.3 : 0.08), in: Capsule())
                        .overlay { Capsule().stroke(tag.color.swiftUIColor.opacity(0.5)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag.name), \(selected ? "selected" : "not selected")")
            }
        }
    }
}

private struct TagEditorRow: View {
    let tag: BoardTag
    let onSave: (BoardTag) -> Void
    @State private var name: String
    @State private var color: BoardTagColor

    init(tag: BoardTag, onSave: @escaping (BoardTag) -> Void) {
        self.tag = tag
        self.onSave = onSave
        _name = State(initialValue: tag.name)
        _color = State(initialValue: tag.color)
    }

    var body: some View {
        HStack {
            TextField("Name", text: $name)
            Picker("Color", selection: $color) {
                ForEach(BoardTagColor.allCases, id: \.self) { choice in
                    Text(choice.rawValue.capitalized).tag(choice)
                }
            }
            Button("Save") {
                var updated = tag
                updated.name = name
                updated.color = color
                onSave(updated)
            }
            if !tag.isBuiltIn {
                Button("Archive") {
                    var updated = tag
                    updated.isArchived = true
                    onSave(updated)
                }
            }
        }
    }
}

private extension BoardSubject {
    var isStack: Bool {
        if case .stack = self { return true }
        return false
    }
}

private extension BoardTagColor {
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
