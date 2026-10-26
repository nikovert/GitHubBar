# PR management and review workspace

The user approved the Safari prototype on 26 October 2026 and requested implementation.
Expand the existing native workspace window; retain the menu bar and its PR navigation.

## Experience

- A spacious, opaque window in light and dark mode, with Manage PRs and Review modes.
- Sidebar queues for attention, authored PRs, requested reviews, pinned PRs, snoozed
  PRs, and all PRs. Search titles, repositories, authors, and PR numbers locally.
- Management rows show titles, authors, requested reviewers, priority and its reason,
  age, GitHub activity, agent status, and next action. Missing data stays unknown.
- Review mode shows a selected PR, overview/changes/threads tabs, file navigation,
  unified and split diffs, viewed-file state, and changes since the last local review.
- Select a diff line to draft an inline comment or ask the agent about that line.
  Comments remain local until the user explicitly submits a GitHub review.
- Review drafts, viewed files, and last reviewed commit survive restarts and are
  scoped by account, PR, head, and base. Changed diffs never silently rebase drafts.
- An optional right-hand agent panel provides contextual questions and cited answers.
  A separately configured JSON command adapter supports any agent; no personal agent
  is named or hardcoded. Terminal sessions remain available through existing controls.
- Existing priority, notes, tags, stack members, worktree setup, sessions, cleanup,
  and agent fix/comment/reply policies remain available in a Workspace tab.

## Data and safety

Use authenticated GitHub APIs through the monitored account. Fetch complete paginated
files and comments with explicit partial-data notices and bounded responses. Preserve
PR head identity through loading and review submission. An explicit user submission
posts one review; tests must never post real reviews or start real agents.

The chat adapter receives the selected PR/head, bounded diff context, conversation,
selection, and effective policy. Chat is advisory: it has no GitHub credential and
does not implicitly enqueue reviews, publish comments, or change files. Adapter
availability is distinct from an existing review worker being enabled. Stop/timeout,
invalid output, and wrong PR/revision responses must produce understandable states.

Created time must come from GitHub. Human activity is shown only when actually measured;
otherwise show GitHub update time and avoid claiming that it excludes bots. Persistent
state must not bleed between accounts. No Slack messages are sent by this feature.

## Delivery

Native SwiftUI/AppKit on macOS 14+, Swift 6 concurrency, existing core package,
no new third-party dependencies. Provide tested source and a universal validation ZIP.
Remote publishing and installing the app are separate actions.
