import GitHubBarCore
import SwiftUI

struct ReviewDetailView: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var workspace: WorkspaceModel
    let pullRequest: PullRequestPresentation?
    let stacks: [PullRequestStack]
    @State private var submissionTarget: ReviewSubmissionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subject = workspace.selectedSubject {
                header(subject)
                Picker("PR detail", selection: $review.tab) {
                    ForEach(ReviewWorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 14)
                Divider()
                if review.tab == .workspace {
                    WorkspaceDetailView(workspace: workspace, subject: subject,
                        stackRoot: subject.isStack ? nil : stacks.first { $0.pullRequests.contains { $0.url == subject.key.url } }?
                            .root.flatMap { try? PullRequestKey(url: $0.url) },
                        details: BoardSubjectDetails.resolve(subject: subject,
                            pullRequests: pullRequest.map { [$0] } ?? [], stacks: stacks))
                        .id(subject)
                } else if review.loading {
                    VStack(spacing: 12) { ProgressView(); Text("Loading PR, changes, and discussion…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot = review.snapshot {
                    switch review.tab {
                    case .overview: overview(snapshot)
                    case .changes: ReviewDiffView(review: review)
                    case .threads: threads(snapshot)
                    case .workspace: EmptyView()
                    }
                } else {
                    ContentUnavailableView("PR details unavailable", systemImage: "network",
                        description: Text("Connect GitHub in Settings or refresh to retry."))
                    Button("Retry") { review.refresh() }.padding()
                }
                footer
            } else {
                ContentUnavailableView("Choose a pull request", systemImage: "arrow.triangle.pull",
                    description: Text("Select a PR from your queues to read its code, review, or ask an agent."))
            }
        }
        .sheet(item: $submissionTarget) { target in ReviewSubmissionView(review: review, target: target) }
    }

    private func header(_ subject: BoardSubject) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Link(subject.key.description, destination: subject.key.url).font(.caption)
                Spacer()
                if let identity = review.identity {
                    Button {
                        review.local.setPinned(!review.local.isPinned(identity), for: identity)
                    } label: { Image(systemName: review.local.isPinned(identity) ? "pin.fill" : "pin") }
                    .help("Pin this PR")
                }
                Link(destination: subject.key.url) { Image(systemName: "arrow.up.right.square") }
                    .help("Open PR on GitHub")
            }
            Text(review.snapshot?.title ?? pullRequest?.title ?? subject.key.description)
                .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("@\(review.snapshot?.author ?? pullRequest?.author?.displayName ?? "unknown")")
                if let created = review.snapshot?.createdAt ?? pullRequest?.createdAt {
                    Text("Opened \(created, style: .relative) ago")
                }
                if subject.isStack { Text("Stack root") }
            }.font(.caption).foregroundStyle(.secondary)
            if let pr = pullRequest {
                HStack {
                    Text(pr.reviewDecision?.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? (pr.isDraft ? "Draft" : "Awaiting review"))
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    Text("Reviewers: \(requestedReviewerSummary(for: pr))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let snapshot = review.snapshot {
                Text(snapshot.checksSummary).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }

    private func overview(_ snapshot: PRReviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let pr = pullRequest {
                    let priority = workspace.reviewPriority(for: workspace.reviewContext(for: pr))
                    GroupBox {
                        HStack(alignment: .top) {
                            Image(systemName: "flag.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(priority.label) priority").font(.headline)
                                Text(priority.reason).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(7)
                    }
                }
                Text("Description").font(.headline)
                Text(snapshot.body.isEmpty ? "No description provided." : snapshot.body)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !snapshot.notices.isEmpty {
                    ForEach(snapshot.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                if let pr = pullRequest {
                    WorkspaceReviewRequestView(workspace: workspace, pullRequest: pr)
                }
                if let identity = review.identity {
                    let older = review.local.previousDraftIdentities(identity)
                    if !older.isEmpty {
                        DisclosureGroup("Drafts retained from earlier diffs (\(older.count))") {
                            ForEach(older, id: \.self) { oldIdentity in
                                let draft = review.local.draft(for: oldIdentity)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Commit \(oldIdentity.headSHA.prefix(8)) · Base \(oldIdentity.baseSHA.isEmpty ? "unrecorded" : String(oldIdentity.baseSHA.prefix(8)))").font(.caption.bold())
                                    Text(draft.body).textSelection(.enabled)
                                    ForEach(draft.comments) { comment in
                                        Text("\(comment.path):\(comment.line) · \(comment.body)").textSelection(.enabled)
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
                Text("Notes, tags, policy overrides, stacks, and pinned terminal sessions are available in Workspace.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threads(_ snapshot: PRReviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !review.draft.comments.isEmpty {
                    Text("Your local inline drafts").font(.headline)
                    ForEach(review.draft.comments) { comment in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(comment.path):\(comment.line) · \(comment.side)").font(.caption).foregroundStyle(.secondary)
                                Text(comment.body).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") { review.editDraft { $0.comments.removeAll { $0.id == comment.id } } }
                                .disabled(review.submitting)
                        }
                        Divider()
                    }
                }
                Text("GitHub discussion").font(.headline)
                if snapshot.comments.isEmpty { Text("No comments available.").foregroundStyle(.secondary) }
                ForEach(snapshot.comments) { comment in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("@\(comment.author)").font(.subheadline.bold())
                            if let date = comment.createdAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if let url = comment.url { Link("GitHub ↗", destination: url).font(.caption) }
                        }
                        if let path = comment.path { Text(path + (comment.line.map { ":\($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if comment.replyToID != nil { Text("Reply in thread").font(.caption).foregroundStyle(.secondary) }
                        Text(comment.body).textSelection(.enabled)
                    }
                    Divider()
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let notice = review.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            HStack {
                Text("\(review.draft.comments.count) inline drafts · Saved locally")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Mark reviewed") { review.markReviewed() }
                    .disabled(review.snapshot == nil || review.submitting || !review.local.canSave)
                Button("Submit review…") {
                    if let identity = review.identity, let snapshot = review.snapshot {
                        submissionTarget = ReviewSubmissionTarget(identity: identity, title: snapshot.title,
                            ownPR: snapshot.author.lowercased() == identity.account.lowercased())
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(review.snapshot == nil || review.sinceLastReview || review.submitting || !review.local.canSave)
            }.padding(12)
        }
    }
}

struct ReviewSubmissionTarget: Identifiable {
    let identity: ReviewIdentity
    let title: String
    let ownPR: Bool
    var id: String { identity.revisionKey }
}

struct ReviewSubmissionView: View {
    @Bindable var review: ReviewWorkspaceModel
    let target: ReviewSubmissionTarget
    @State private var event = "COMMENT"
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool { review.identity == target.identity && review.local.canSave && !review.submitting }
    private var draft: WorkspaceReviewDraft { review.local.draft(for: target.identity) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit review to GitHub").font(.title2.bold())
            Text(target.title).font(.headline)
            Text("\(draft.comments.count) inline comments · @\(target.identity.account) · Commit \(target.identity.headSHA.prefix(8))")
                .foregroundStyle(.secondary)
            if !valid {
                Text("The PR, account, or diff changed. Cancel and reopen this sheet after reviewing the current changes. Your original draft is retained.")
                    .foregroundStyle(.orange)
            }
            TextEditor(text: Binding(get: { draft.body }, set: { value in if valid { review.editDraft { $0.body = value } } }))
                .frame(minHeight: 150).border(Color.secondary.opacity(0.3))
                .disabled(!valid)
            Picker("Review decision", selection: $event) {
                Text("Comment").tag("COMMENT")
                if !target.ownPR { Text("Approve").tag("APPROVE"); Text("Request changes").tag("REQUEST_CHANGES") }
            }.pickerStyle(.radioGroup)
            Text("This posts your review and inline drafts to GitHub as your monitored account.")
                .font(.caption).foregroundStyle(.secondary)
            if event != "APPROVE" {
                Text("Add a summary above to submit a Comment or Request changes review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Submit to GitHub") {
                    if let choice = PRReviewEvent(rawValue: event) { review.submit(event: choice, target: target.identity) }
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(!valid || (event != "APPROVE" && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(24).frame(width: 560)
    }
}
