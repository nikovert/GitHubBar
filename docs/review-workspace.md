# Manage and review pull requests

Open **Workspace Board** from GitHubBar, or click a PR in the menu or search results.
The larger workspace has **Manage PRs** and **Review** modes. Existing sessions,
notes, tags, setup, and cleanup remain available.

## Manage PRs

Use the sidebar to switch between PRs needing attention, your PRs, requested
reviews, pinned PRs, snoozed PRs, and all PRs in your workload. Search this list by
title, repository, author, or number. The existing extended search still searches
outside your workload and opens its results in the same workspace.

Rows show the title and author, requested reviewers, priority and its reason, age,
GitHub activity, and the next action. Age comes from GitHub's created timestamp;
old cached data can show "Age unavailable" until refreshed. Activity is GitHub's
update time, which can include bots; it is not a last-human-interaction metric.

Right-click a PR in the workspace for pinning, a 24-hour snooze, GitHub navigation,
or stack management. Pins and snoozes are local and specific to your monitored
account. Menu-bar and search-result right-clicks still open GitHub directly.

## Review code

- **Overview** shows the description, priority reason, review request, and retained
  drafts from earlier diffs.
- **Changes** shows files and unified or split diffs. Drag the file divider to
  resize the list; use horizontal scrolling for wide code. Hide the agent panel
  with the top-right sidebar button when you need more room.
- **Threads** shows GitHub conversation and inline review comments, plus your local
  inline drafts. Links open the original GitHub thread.
- **Workspace** contains the existing notes, tags, priorities, review policies,
  stack members, terminal sessions, and worktree configuration.

Click a diff line to draft an inline comment or ask the agent about that line.
Drafts are saved locally. **Submit review…** opens a summary and decision sheet;
**Submit to GitHub** is the action that publishes the review. A summary is required
for a Comment or Request changes review. Approving your own PR is not offered.

Drafts and viewed-file state are tied to the account, PR, head, and base commits. New
commits or a changed base start separate state; older drafts remain accessible in
Overview, and are never automatically transplanted to new lines. The submission
sheet stays bound to the PR and diff it was opened for. Failed submissions retain drafts.
If a submission's outcome is uncertain, inspect GitHub before retrying.

**Mark reviewed** saves a local baseline without posting anything. Submitting a
review also saves its head as the baseline. **Since my last review** compares that
commit with the current head. Inline drafting is disabled in comparison mode to
avoid posting comparison coordinates as PR coordinates. GitHub may compare from a
merge base after a force-push; a notice explains this when detected.

Binary files, omitted/truncated patches, and API pagination limits are explicitly
reported. Inline drafting is available only with a complete file list and a complete
patch for the selected file. Use the GitHub link for missing code. Local review state is stored in
this Mac's app preferences and is not synchronized with GitHub's viewed state.

## Ask an agent

Open **Settings → Workspace chat → Configure chat agent**, or use the gear in the
agent panel. **Use an installed CLI…** loads a preset for an installed and locally
authenticated Codex or Claude CLI. The bundled adapter needs Python 3. No provider
request is made when selecting a preset or checking paths.

Alternatively, connect any command supporting the [JSON chat protocol](agent-chat.md).
The adapter receives the PR description, a bounded diff excerpt, selected-line
context, and recent conversation. It returns an answer and optional file/line
citations. Click a citation to navigate if that line is present in the loaded diff.
Answers appear when complete; **Stop** cancels a request.

Chat is advisory. Review-worker fix, comment, and reply permissions remain separate;
asking a question does not request a background review or publish a comment. Existing
terminal-only agents still work through **Jump to session** in Workspace. The worker
queue uses its existing configuration; enabling it does not enable chat automatically.

Use the toolbar's **… → Clean up merged worktrees…** for the existing verified
cleanup flow, including titles/descriptions and explicit session choices.
