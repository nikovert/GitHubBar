<div align="center">

# GitHubBar

### Review at scale, from your menu bar.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0d1117?style=flat-square&logo=apple&logoColor=white)](https://github.com/nikovert/GitHubBar/releases)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org/)

<img src="docs/assets/githubbar-hero.png" alt="GitHubBar showing a high-volume pull-request review queue in the macOS menu bar" width="100%" />

**The number in your menu bar is your review queue.** Open GitHubBar to see review requests and your own pull requests across the repositories that matter on this Mac.

[Download a validation build](https://github.com/nikovert/GitHubBar/releases) · [Build this fork](#build-from-source) · [Report an issue](https://github.com/nikovert/GitHubBar/issues)

</div>

> This is a development fork of
> [FranciscoMoretti/GitHubBar](https://github.com/FranciscoMoretti/GitHubBar).
> Upstream releases do **not** include the workspace board or agent-session features below.

## Workspace additions in this fork

- Follow macOS appearance or choose Light or Dark in Settings.
- Keep local priority, status tags, and agent notes for each PR or stack. PRs inherit stack
  values until overridden. The board is stored only on this Mac.
- Scan PR titles, authors, requested reviewers, review status, and stack members in the board.
- Create a new Codex or Claude worktree/tmux session, or pin an existing one.
- Select a PR with a running pinned agent from the menu to jump into its tmux session.
  Right-click a PR to edit its board entry, or open **Workspace Board…** from the menu.
- Let local agents update the board with the `GitHubBarWorkspaceCLI` command. See
  [Agent workspace guide](docs/agent-workspace.md).

## Built for review at scale

- **Know what needs you.** The menu-bar count shows open pull requests currently awaiting your review—GitHubBar's only proactive attention signal.
- **See your whole review workflow.** Scan Needs your review, Returned to you, Needs reviewers, Waiting for reviewers, Approved, and Drafts in one native menu.
- **Keep people visible.** Every row shows the author and review roster, so missing reviewers and completed reviews are easy to spot.
- **Focus each Mac.** Switch instantly between all accessible repositories and a device-local pinned set configured in Settings.
- **Navigate stacked work.** Linear pull-request stacks collapse into compact, section-aware rows; open the submenu to see every member's current section and reviewers.
- **Move without the website.** Open any pull request directly, refresh on demand, or press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>G</kbd> from anywhere.

GitHubBar reconciles the full account workload in the background, keeps the latest useful snapshot available, and applies repository scope locally—switching views does not trigger another GitHub request.

## Install

Download this fork's **validation prerelease** from
[nikovert/GitHubBar releases](https://github.com/nikovert/GitHubBar/releases). The
[upstream releases](https://github.com/FranciscoMoretti/GitHubBar/releases) do not
include the workspace board or agent sessions.

1. Install and sign in to [GitHub CLI](https://cli.github.com/):

   ```sh
   brew install gh
   gh auth login
   ```

2. Download the validation ZIP and adjacent `.sha256` file, then verify them:

   ```sh
   cd ~/Downloads
   shasum -a 256 --check GitHubBar-validation-*.zip.sha256
   ```

3. Unzip GitHubBar and move it to **Applications**.

This validation build is ad-hoc signed, not Apple-notarized, and does not update itself.
On first launch, macOS may block it: try opening GitHubBar once, then choose **Open
Anyway** under **System Settings → Privacy & Security** after verifying the checksum.
Its `com.nikovert.githubbar` bundle ID is separate from the upstream app.

GitHubBar requires macOS 14 or newer and runs on both Apple silicon and Intel Macs.
Developer ID signing, notarization, and automatic updates remain planned for a future release.

## Privacy

GitHubBar uses your existing GitHub CLI login. Tokens stay in memory, preferences and the latest PR snapshot stay on your Mac, and diagnostics never record repository names, PR titles, usernames, or credentials.

## Build from source

```bash
brew install xcodegen gh tmux
scripts/generate-project.sh
open GitHubBar.xcodeproj
```

Build and run the `GitHubBar` scheme in Xcode. Install and authenticate `gh`, then set a
local checkout and worktree root in **Workspace Board… → Workspace setup** before launching
an agent. Install `codex` or `claude` on your `PATH`. macOS will ask permission to automate
Terminal the first time you jump to a pinned tmux session.

Run `scripts/check.sh` before submitting a pull request. Release details are in the [stable release runbook](docs/releases/stable-release-runbook.md) and [validation guide](docs/releases/validation-release.md).

---

<div align="center">
<sub>Built for developers who would rather review the PR than find the PR.</sub>
</div>
