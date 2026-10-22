# Local agent workspace

This fork adds a local board and pinned Codex/Claude sessions to the menu-bar PR view.
It does not write board metadata to GitHub or Slack. The board file lives at
`~/Library/Application Support/GitHubBar/workspace.json`, with owner-only permissions.
Agents and the app coordinate edits using a local lock and atomic writes. Do not edit the
JSON file directly while GitHubBar is running.

## Set up

Build this fork with full Xcode, then open **Workspace Board…** in the menu.
Under **Workspace setup**, provide an absolute path to the local checkout for each
repository and an absolute worktree root outside those checkouts. New worktrees fetch
`pull/NUMBER/head` from the checkout's `origin` remote. GitHubBar refuses to launch
unless `origin` points at the GitHub repository that owns the PR. A fork-only `origin`
may not expose its PR refs.

Install tmux and either or both agent CLIs:

```bash
brew install tmux
command -v codex
command -v claude
```

The **New Codex worktree** and **New Claude worktree** buttons fetch the PR head, create a
new local branch/worktree, and start the agent in a named tmux session. The menu's PR row
opens the running session in Terminal. You can also pin an existing worktree and optional
tmux session name in the board. A session pinned to a stack is available from its member
PRs. Stopping kills only the linked tmux session. Restarting starts it again in the same
worktree.

**Remove worktree** is available only for worktrees created by GitHubBar. It refuses to
remove one with uncommitted or ignored files. **Unpin** removes the local link only; it does not
stop tmux or delete files.

## Let agents update the board

From the repository root, build the command-line client:

```bash
swift build --package-path Packages/GitHubBarCore --product GitHubBarWorkspaceCLI
```

Then ask Codex or Claude to use it for their local progress. Example:

```bash
swift run --package-path Packages/GitHubBarCore GitHubBarWorkspaceCLI set \
  --pr https://github.com/OWNER/REPO/pull/123 \
  --priority high \
  --tags blocked,agent-needs-attention \
  --note "Tests pass; waiting for API decision" \
  --by codex
```

Use `--stack` with the root PR URL to set stack defaults. Omitting a field leaves its
previous value intact. `--priority none` clears the priority; `--tags ""` clears tags;
`--note ""` clears the note. Built-in tag IDs are `blocked`, `waiting-on-review`,
`needs-rework`, `ready-to-merge`, `agent-running`, and `agent-needs-attention`. Create
and edit custom tags in the board window. To inspect the current document:

```bash
swift run --package-path Packages/GitHubBarCore GitHubBarWorkspaceCLI show
```

For testing without touching your real board, set `GITHUBBAR_WORKSPACE_DIR` to an
absolute temporary directory when invoking the CLI. The app always uses its normal
Application Support location.

## Boundaries

GitHubBar does not automatically run a code review or post review comments. A pinned
agent stays local until you explicitly ask it to review or publish something. The board
can contain private notes and paths, so do not commit `workspace.json` to a repository.
This fork currently opens linked sessions in Apple Terminal; it does not re-focus an
existing Terminal tab, but attaches to the same tmux session.
