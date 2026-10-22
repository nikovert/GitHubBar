import AppKit
import GitHubBarCore
import SwiftUI

struct WorkspaceAgentReviewView: View {
    @Bindable var workspace: WorkspaceModel
    let subject: BoardSubject?
    let pullRequest: PullRequestPresentation?

    private var isStack: Bool {
        if case .stack = subject { return true }
        return false
    }

    var body: some View {
        GroupBox("Agent review") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    workspace.monitoredAccountLogin.map { "Enable agent reviews for @\($0)" }
                        ?? "Connect a GitHub account to enable agent reviews",
                    isOn: Binding(
                        get: { workspace.reviewDocument.enabled && !workspace.reviewAccountMismatch },
                        set: { workspace.configureReviews(enabled: $0) }
                    )
                )
                .disabled(!workspace.canConfigureReviews)
                Text("Requests wait for a compatible review worker. Configure its connection in Settings. Enabling reviews does not install or start a worker.")
                    .font(.caption).foregroundStyle(.secondary)
                if workspace.reviewAccountMismatch {
                    Text("Configured for @\(workspace.reviewDocument.accountLogin). Use a separate workspace for the monitored account.")
                        .foregroundStyle(.red)
                }
                DisclosureGroup("Global defaults") {
                    WorkspaceReviewPolicyControls(workspace: workspace, subject: nil)
                        .padding(.top, 6)
                }
                if let subject {
                    Divider()
                    Text(isStack ? "Stack policy" : "PR policy").font(.subheadline.bold())
                    WorkspaceReviewPolicyControls(workspace: workspace, subject: subject)
                    Text(isStack
                         ? "Members inherit this policy unless they have a PR override. Request reviews individually above."
                         : "PR overrides take precedence over stack policy and global defaults.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let pullRequest, !isStack {
                    WorkspaceReviewRequestView(workspace: workspace, pullRequest: pullRequest)
                }
                Text("Fixes on another author's PR require an explicit fix mode on that PR. Global and stack fix settings do not opt it in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
        }
    }
}

struct WorkspaceReviewPolicyControls: View {
    @Bindable var workspace: WorkspaceModel
    let subject: BoardSubject?

    private var policy: AgentReviewPolicy { workspace.reviewPolicy(for: subject) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Fix mode", selection: Binding(
                get: { policy.fixMode?.rawValue ?? "inherit" },
                set: { workspace.setReviewFixMode(AgentFixMode(rawValue: $0), for: subject) }
            )) {
                Text(subject == nil ? "Default: off" : "Inherit").tag("inherit")
                ForEach(AgentFixMode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            Picker("Publish comments", selection: Binding(
                get: { selection(policy.comments) },
                set: { workspace.setReviewComments(value($0), for: subject) }
            )) {
                Text(subject == nil ? "Default: own PRs only" : "Inherit").tag("inherit")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            Picker("Reply to comments", selection: Binding(
                get: { selection(policy.replies) },
                set: { workspace.setReviewReplies(value($0), for: subject) }
            )) {
                Text(subject == nil ? "Default: off" : "Inherit").tag("inherit")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
        }
        .disabled(workspace.monitoredAccountLogin == nil || workspace.reviewAccountMismatch)
    }

    private func selection(_ value: Bool?) -> String {
        value.map { $0 ? "on" : "off" } ?? "inherit"
    }

    private func value(_ selection: String) -> Bool? {
        selection == "inherit" ? nil : selection == "on"
    }
}

struct WorkspaceReviewRequestView: View {
    @Bindable var workspace: WorkspaceModel
    let pullRequest: PullRequestPresentation

    private var context: AgentPRContext { workspace.reviewContext(for: pullRequest) }
    private var latest: AgentReviewJob? { workspace.latestReview(for: context) }
    private var unavailable: String? { workspace.reviewUnavailableReason(for: context) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let effective = workspace.reviewDocument.effectivePolicy(for: context)
            Text("Effective policy: \(effective.fixMode?.label ?? AgentFixMode.off.label) · Comments \(effective.comments == true ? "on" : "off") · Replies \(effective.replies == true ? "on" : "off")")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button(latest == nil ? "Request review" : "Re-request review") {
                    workspace.requestReview(context)
                }
                .disabled(unavailable != nil)
                .help(unavailable ?? "Request an agent review of the current head commit")
                .accessibilityLabel("\(latest == nil ? "Request" : "Re-request") agent review for PR #\(pullRequest.number)")
                if let latest {
                    Text(WorkspaceReviewContext.status(latest, currentSHA: context.headSHA))
                        .font(.caption.weight(.medium))
                } else {
                    Text("Not requested").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.secondary)
            }
            if let latest {
                if latest.status == .queued {
                    Text("Queued — waiting for a compatible review worker. If this persists, check that the worker is running and configured for this account and workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Requested \(latest.requestedAt, style: .relative) · SHA \(String(latest.headSHA.prefix(12)))")
                    .font(.caption2).foregroundStyle(.secondary)
                if !latest.summary.isEmpty {
                    Text(latest.summary).textSelection(.enabled)
                }
                if !latest.error.isEmpty {
                    Text(latest.error).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if let url = webURL(latest.githubURL) { Link("Review on GitHub ↗", destination: url) }
                    if let url = webURL(latest.slackURL) { Link("Open Slack ↗", destination: url) }
                }
                if let path = latest.worktreePath, !path.isEmpty {
                    Text("Fix worktree").font(.caption.weight(.medium))
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    if path.hasPrefix("/") {
                        HStack {
                            Link("Open in Finder", destination: URL(fileURLWithPath: path, isDirectory: true))
                            Button("Open Terminal") { workspace.openReviewWorktree(path) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
