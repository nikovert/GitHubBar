import AppKit
import GitHubBarCore
import SwiftUI

struct ReviewWorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var appModel: AppModel
    @State var review = ReviewWorkspaceModel()
    @State private var showsCleanup = false
    @State private var showsChatSettings = false

    private var account: String? { workspace.monitoredAccountLogin }
    private var allPRs: [PullRequestPresentation] {
        var seen = Set<String>()
        return (workspace.pullRequests(in: appModel.state) + appModel.state.pullRequestStacks.flatMap(\.pullRequests))
            .filter { seen.insert($0.url.absoluteString).inserted }
            .sorted {
                WorkspaceReviewContext.precedes(workspace.reviewContext(for: $0), workspace.reviewContext(for: $1),
                    in: workspace.document, priorityAuthors: workspace.reviewDocument.priorityAuthors)
            }
    }
    private var selectedPR: PullRequestPresentation? { allPRs.first { $0.url == workspace.selectedSubject?.key.url } }
    private var filtered: [PullRequestPresentation] {
        rows(in: review.queue).filter {
            review.search.isEmpty || "\($0.title) \($0.repositoryNameWithOwner) #\($0.number) \($0.author?.displayName ?? "")"
                .localizedCaseInsensitiveContains(review.search)
        }
    }
    private var navigationID: String {
        "\(account ?? "")|\(workspace.selectedSubject?.key.description ?? "")|\(selectedPR?.headSHA ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 230)
                Divider()
                if review.mode == .manage {
                    management
                } else {
                    ReviewDetailView(review: review, workspace: workspace, pullRequest: selectedPR,
                        stacks: appModel.state.pullRequestStacks)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if review.showsAgent {
                        Divider()
                        ReviewChatPanel(review: review, workspace: workspace, pullRequest: selectedPR,
                            showsSettings: $showsChatSettings)
                            .frame(width: 290)
                    }
                }
            }
            if let error = review.errorMessage ?? workspace.errorMessage ?? review.local.errorMessage {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { review.errorMessage = nil; workspace.errorMessage = nil }
                }
                .padding(12).background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(isPresented: $showsCleanup) { WorktreeCleanupView(model: workspace.cleanup) }
        .sheet(isPresented: $showsChatSettings) { ReviewChatSettingsView() }
        .onAppear {
            if workspace.selectedSubject != nil { review.mode = .review }
        }
        .onChange(of: workspace.selectedSubject) { _, subject in
            if subject != nil { review.mode = .review }
        }
        .task(id: navigationID) {
            review.select(workspace.selectedSubject?.key, account: account, force: true)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.pull").font(.title3).foregroundStyle(.blue)
            Text("GitHubBar Workspace").font(.headline)
            Picker("Mode", selection: $review.mode) {
                ForEach(ReviewWorkspaceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Spacer()
            if appModel.state.isRefreshing || review.loading { ProgressView().controlSize(.small) }
            Button { appModel.send(.manualRefresh); review.refresh(); Task { await workspace.reload() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.help("Refresh GitHub and local workspace status")
            Menu {
                Button("Clean up merged worktrees…") { showsCleanup = true; workspace.cleanup.scan() }
                    .disabled(account == nil)
                Button("Configure chat agent…") { showsChatSettings = true }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            if review.mode == .review {
                Toggle(isOn: $review.showsAgent) { Image(systemName: "sidebar.right") }
                    .toggleStyle(.button).help("Show or hide the agent panel")
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR WORK").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
            ForEach(ReviewWorkspaceQueue.allCases, id: \.self) { queue in
                Button { review.queue = queue } label: {
                    HStack {
                        Label(queue.rawValue, systemImage: queue.icon)
                        Spacer()
                        Text("\(rows(in: queue).count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(review.queue == queue ? Color.accentColor.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
            TextField("Find a PR…", text: $review.search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(filtered) { pr in
                        Button { select(pr, openReview: true) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("#\(pr.number)").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if review.local.isPinned(identity(pr)) { Image(systemName: "pin.fill").font(.caption2) }
                                }
                                Text(pr.title).font(.subheadline.weight(.medium)).lineLimit(3)
                                Text("@\(pr.author?.displayName ?? "unknown") · \(pr.repositoryNameWithOwner)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text(nextAction(pr)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(workspace.selectedSubject?.key.url == pr.url ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { prActions(pr) }
                    }
                    if filtered.isEmpty { Text("No PRs in this view.").foregroundStyle(.secondary).padding(.top, 20) }
                }
            }
            Text(account.map { "@\($0)" } ?? "Connect GitHub in Settings")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(review.queue.rawValue).font(.largeTitle.weight(.semibold))
                    Text("\(filtered.count) pull requests · Prioritized for your next action")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Label("Pull request", systemImage: "arrow.triangle.pull").frame(maxWidth: .infinity, alignment: .leading)
                Text("Priority").frame(width: 140, alignment: .leading)
                Text("Age / activity").frame(width: 145, alignment: .leading)
                Text("Next action").frame(width: 180, alignment: .leading)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { pr in
                        let context = workspace.reviewContext(for: pr)
                        let priority = workspace.reviewPriority(for: context)
                        HStack(alignment: .top, spacing: 12) {
                            Button { select(pr, openReview: true) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(pr.title).font(.headline).foregroundStyle(.primary)
                                    Text("\(pr.repositoryNameWithOwner)#\(pr.number) · @\(pr.author?.displayName ?? "unknown")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Requested: \(requestedReviewerSummary(for: pr))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(priority.label).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(priority.rank >= 3 ? Color.orange : Color.secondary)
                                Text(priority.reason).font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 140, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                if let created = pr.createdAt { Text("Opened \(created, style: .relative) ago") }
                                else { Text("Age unavailable") }
                                Text("Updated \(pr.updatedAt, style: .relative) ago")
                            }.font(.caption).foregroundStyle(.secondary).frame(width: 145, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(nextAction(pr)).font(.caption)
                                if let job = workspace.latestReview(for: context) {
                                    Text("Agent · \(job.displayStatus(currentSHA: pr.headSHA))").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Review PR") { select(pr, openReview: true) }.controlSize(.small)
                            }.frame(width: 180, alignment: .leading)
                        }.padding(12).contextMenu { prActions(pr) }
                        Divider()
                    }
                }
            }
            Text("Activity is GitHub's update time and may include bots. Open a PR to inspect its discussion and code.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func identity(_ pr: PullRequestPresentation) -> ReviewIdentity {
        ReviewIdentity(account: account ?? "", prURL: pr.url.absoluteString, headSHA: pr.headSHA ?? "")
    }
    private func rows(in queue: ReviewWorkspaceQueue) -> [PullRequestPresentation] {
        allPRs.filter { pr in
            let id = identity(pr)
            let snoozed = review.local.isSnoozed(id)
            switch queue {
            case .all: return true
            case .snoozed: return snoozed
            case .pinned: return review.local.isPinned(id)
            case .mine: return !snoozed && pr.author?.displayName.lowercased() == account?.lowercased()
            case .requested: return !snoozed && appModel.state.needsYourReview.contains { $0.url == pr.url }
            case .attention:
                return !snoozed && (appModel.state.needsYourReview.contains { $0.url == pr.url }
                    || pr.reviewDecision == .changesRequested
                    || workspace.latestReview(for: workspace.reviewContext(for: pr)).map {
                        $0.status == .failed || $0.status == .completed
                    } == true)
            }
        }
    }
    private func nextAction(_ pr: PullRequestPresentation) -> String {
        if pr.isDraft { return "Draft in progress" }
        if pr.reviewDecision == .changesRequested { return "Address review feedback" }
        if let job = workspace.latestReview(for: workspace.reviewContext(for: pr)) {
            if job.status == .failed { return "Agent needs attention" }
            if job.status == .completed {
                return job.headSHA == pr.headSHA ? "Read agent findings" : "Re-request agent review"
            }
        }
        if appModel.state.needsYourReview.contains(where: { $0.url == pr.url }) { return "Your review is requested" }
        if pr.reviewDecision == .approved { return "Approved · check merge readiness" }
        return "Waiting for reviewers"
    }
    private func select(_ pr: PullRequestPresentation, openReview: Bool) {
        workspace.openPullRequest(pr)
        if openReview { review.mode = .review }
    }
    @ViewBuilder private func prActions(_ pr: PullRequestPresentation) -> some View {
        Button("Open review") { select(pr, openReview: true) }
        Link("Open on GitHub", destination: pr.url)
        Button(review.local.isPinned(identity(pr)) ? "Unpin PR" : "Pin PR") {
            review.local.setPinned(!review.local.isPinned(identity(pr)), for: identity(pr))
        }
        Button(review.local.isSnoozed(identity(pr)) ? "Unsnooze" : "Snooze for 24 hours") {
            review.local.snooze(until: review.local.isSnoozed(identity(pr)) ? nil : Date.now.addingTimeInterval(86400), for: identity(pr))
        }
        if let stack = appModel.state.pullRequestStacks.first(where: { $0.pullRequests.contains { $0.url == pr.url } }),
           let root = stack.root, let key = try? PullRequestKey(url: root.url) {
            Button("Manage stack") { workspace.selectedSubject = .stack(key); review.mode = .review; review.tab = .workspace }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
