# Agent reviews

GitHubBar exchanges local review requests and results with an optional Giles worker
through `GitHubBarWorkspaceCLI agent`. The CLI is bundled in
`GitHubBar.app/Contents/MacOS` in validation, stable, and Xcode builds. Giles remains a
separate installation; existing external Giles path setup is optional. Installing
GitHubBar alone does not start a review worker.

See the [agent review protocol](agent-review-protocol.md) for bridge operations,
request fields, response formats, and queue semantics.

## Setup and approved defaults

Use the same macOS account and workspace directory for GitHubBar and Giles. The normal
directory is `~/Library/Application Support/GitHubBar`; the CLI accepts an absolute
`GITHUBBAR_WORKSPACE_DIR` override for isolated tests. Review state lives in
`agent-reviews.json`, separate from board metadata in `workspace.json`. Both use local
locking and atomic writes. Do not edit them directly while clients are running.

Inspect the bridge without enabling a worker:

```bash
workspace_cli="/Applications/GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI"
printf '%s\n' '{"op":"show"}' | "$workspace_cli" agent
```

Use the app's actual location. Giles reads its JSON configuration from `config.json`
in its checkout, or from the path passed to `python -m giles.app`. Add a top-level
`bridge` object to your existing configuration, preserving the other settings:

```json
{
  "bridge": {
    "workspace_cli": "/Applications/GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI",
    "github_login": "your-login",
    "slack_dm_user": "U_ALLOWED_USER",
    "enabled": true,
    "poll_interval_seconds": 15,
    "fix_check_commands": [],
    "fix_hook_command": ["pre-commit", "run", "--files"]
  }
}
```

This is a configuration fragment, not a replacement for your existing Giles config.
Replace `your-login` and `U_ALLOWED_USER`; the Slack ID must already appear in the
top-level `allowed_user_ids`. Repository access still follows `allowed_repositories`.
The keys below are nested inside `bridge`, as defined by Giles's `giles/config.py`:

| Setting | Value |
| --- | --- |
| `workspace_cli` | Required absolute path; `~` is not expanded |
| `enabled` | Boolean; defaults to `false`. Set `true` to opt into daemon integration |
| `github_login` | Required personal GitHub login, matching `gh` authentication; letters, digits, and hyphens only |
| `slack_dm_user` | Required existing allowed Slack user ID for board-request notifications |
| `poll_interval_seconds` | Finite number from 1 to 60; defaults to 15 seconds |
| `fix_check_commands` | List of nonempty argv arrays, never shell strings; defaults to `[]` |
| `fix_hook_command` | Nonempty argv array; defaults to `["pre-commit", "run", "--files"]` |

Configure checks appropriate to the reviewed repository before enabling fixes. For
example, `[["python", "-m", "pytest", "tests/test_parser.py"]]` is a valid
`fix_check_commands` value for a Python repository with that test file. Each argv
element must be a nonempty string without a NUL character. Paths and executables
must be available to the Giles process. No separate workspace-directory JSON key
exists; isolated clients use the `GITHUBBAR_WORKSPACE_DIR` environment variable.

With `bridge` absent or `null`, Giles keeps its existing behavior. Setting
`bridge.enabled` to `false` disables daemon integration but still validates the supplied
bridge settings. Configure the local
review document with your account login and enable it only when intentionally opting
in. For example, after replacing `YOUR_LOGIN`:

```bash
printf '%s\n' '{"op":"configure","enabled":true,"account_login":"YOUR_LOGIN"}' \
  | "$workspace_cli" agent
```

Approved initial policies are:

| Action | Own PR | Someone else's PR |
| --- | --- | --- |
| Fixes | Off | Off; requires explicit PR-level opt-in |
| Publish verified review comments | On | Off |
| Automatic replies | Off | Off |

PR overrides take precedence over stack overrides, then global defaults. Stack policy
keys use `stack:` followed by the root PR URL. A `null` field clears an override.
Fix modes are `off`, `low_risk`, and `all`; neither stack nor global fix settings
authorize fixes on another author's PR. Replies, if enabled, apply only to new human
comments in Giles-originated GitHub review threads. Bots and Giles itself are excluded.

## Requests, priority, and progress

Board requests and authorized Slack requests enter the same queue. Slack policy and
priority commands require an allowed user; PR text and thread content confer no
permissions. Board requests report progress to the board and a Slack DM; Slack requests
report to their original thread. Requests can carry focuses and additional instructions.

Manual priority wins. Otherwise, a sole human review request for the configured account
is high priority only when the reviewer roster is complete and no teams are requested.
PRs by `Reina234` or `michaelcraiger` are medium priority; the rest are low. The board
sorts the oldest updated PR first within a priority, while the worker claims the oldest
request first within a priority. Clearing a PR's manual priority restores inherited
stack priority or automatic priority.

Only one job runs globally. A running job has a 180-second lease, renewed at least every
60 seconds. Expired running jobs are persisted as failed on reads/loads, `show`,
`enqueue`, and `claim`; they are not automatically replayed. You can explicitly
re-request a review after lease expiry even if the worker has stopped. Duplicate
requests for a queued job or a running job with an unexpired lease return the existing
job; after completion or failure, an explicit request can run again at the same head SHA.

The bridge reads one JSON object from stdin and returns JSON on stdout, exiting nonzero
on invalid operations. Agent dates are Unix seconds and keys/enums use snake_case.
See the [protocol reference](agent-review-protocol.md) for each operation and its fields.
The ordinary CLI `show`/`set` commands still address the board document.

## Publication and fixes

Giles retains its find-and-verify review pipeline and publishes verified findings only
under the effective policy. GitHub comments and commits are labelled Giles-generated
and use the configured personal account. Policy is checked again before each external
write; disabling integration stops further writes.

Fixes use a separate writable worktree, targeted checks, and commit hooks, with account
and head-SHA guards before remote writes. Low-risk fixes require a risk rationale;
uncertainty prevents a push. `all` permits behavior changes with checks. There is no
force push, amend, or merge. Failed fix worktrees are preserved and reported. An outgoing
action ledger prevents duplicate effects after restart; ambiguous remote writes need
reconciliation or attention rather than an automatic retry.

## Build and verify

From the GitHubBar repository root, create the local universal validation ZIP:

```bash
GITHUBBAR_VERSION=0.1.0 GITHUBBAR_BUILD_NUMBER=1 scripts/package-validation.sh
```

Choose the intended version/build number for a release. This compiles both the app and
CLI for arm64 and x86_64, signs the CLI before the enclosing app with ad-hoc signatures,
verifies both, and writes a ZIP plus SHA-256 file to `dist/`. It does not install the app.
Inspect the packaged CLI with isolated state:

```bash
lipo .build/validation/GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI \
  -verify_arch arm64 x86_64
review_test_dir="$(mktemp -d /private/tmp/githubbar-review-check.XXXXXX)"
printf '%s\n' '{"op":"show"}' \
  | GITHUBBAR_WORKSPACE_DIR="$review_test_dir" \
    .build/validation/GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI agent
```

The temporary review directory is retained for inspection. Do not enable a production
worker or send live Slack/GitHub requests as a packaging test.

For Xcode builds, run `scripts/generate-project.sh`, then build the `GitHubBar` scheme.
Its CLI target shares the Swift package's CLI sources and `GitHubBarCore` library,
uses [XcodeGen's executable copy destination](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#dependency)
to embed it in `Contents/MacOS`, and signs it on copy. The CLI uses
`-parse-as-library` to support its `@main` declaration in `main.swift`.

For a stable universal ZIP, first configure the credentials and release variables in
the [stable release runbook](releases/stable-release-runbook.md), then run:

```bash
scripts/package-stable.sh
```

Stable packaging verifies both executables, their architectures and hardened runtime
signatures before notarization. It writes the final ZIP/checksum and signed appcast to
`dist/stable/`. This path submits to Apple's notarization service and is not an offline
validation command; run it only in the authorized release workflow.

Both scripts validate paths before cleanup. `GITHUBBAR_BUILD_DIR` must be an absolute,
dedicated directory strictly beneath this checkout's `.build/`; that directory is
deleted on each build. `GITHUBBAR_DIST_DIR` must be an absolute path to this checkout's
`dist/` or a descendant. Symlinks and `..` are resolved before checking those boundaries.
Versions must be filename-safe identifiers and build numbers must contain digits only.
Leave these overrides unset to use the defaults above.
