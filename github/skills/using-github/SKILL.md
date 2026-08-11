---
name: using-github
description: |
  How to use the Work42 GitHub plugin together: the github PR browser widget
  and the github-prs Home-surface browser widget. Covers the github PR browser
  widget (session-scoped, github/prs storage, [system event] delivery), the
  github-prs Home widget (one browser tab per workspace repo, no gh CLI needed,
  action-center "Start code review session" enabled on /pull/<N> URLs), and the
  global.review.pr palette intent. Install this plugin with:
  work42 plugin install <path-to-github-plugin>
---

# Using the GitHub plugin

The GitHub plugin ships two complementary widgets that together give you full
PR workflow coverage inside Work42.

## The two widgets

### widget:github — PR browser (session-scoped)

The `github` widget renders one embedded browser tab per pull request attached
to the current session. It runs a 60-second background poll loop inside
`GitHubBackgroundAgent`, a per-(session × widget) `WidgetBackgroundAgent`
managed by `WidgetBackgroundHost`. The loop runs while the session's ACP runner
is alive and the widget is in the session's saved layout — independently of
whether the session panel is open, so events fire and header labels update even
when the user is on Home or another session.

Each poll calls `gh pr view` and `gh api …/comments`, diffs the snapshots, and
delivers new activity (reviews, comments, CI checks, merge/close) as
fingerprinted `[system event]`s. The session header shows live CI / approval
chips sourced from the agent's `headerLabels` property, visible for any tab of
the session (not just the active tab).

The view (`activate`) refreshes its PR tab list from storage on each mount
(`loadAndSyncPRs`) — browser tab status badges update on re-activate, not live
while the panel is open (that is the agent's job).

Use this widget in a **task session** or a **patrol code-review session** where
you know which specific PR you are working on.

Storage: the widget reads and writes `github/prs` (JSON array of PR objects) in
the session's `github` namespace.

### widget:github-prs — Home-surface PRs browser

The `github-prs` widget is a **Home-surface browser widget**. It enumerates git
repositories in the workspace root via `services.shell` (no `gh` CLI required),
reads each repo's `remote.origin.url`, and opens one `BrowserSurface` tab per
repo at `https://github.com/<owner>/<repo>/pulls`.

Use this widget on the **Home surface** to browse open PRs across all workspace
repos. It does not read or write the `github/prs` task-storage key — it
discovers repos fresh on every activation.

**Action-center button — "Start code review session"**

The button appears in the action center while `github-prs` is active. It is:

- **Enabled** when the active tab's URL matches a GitHub PR page
  (URL path contains `/pull/<N>`).
- **Dimmed but visible** when the active tab is on a PR list or any other
  GitHub page.

Its enabled state is driven by `WidgetIntentSpec.isEnabled` — a render-time
closure that reads the current URL from the widget's `BrowserWidgetModel`.

Clicking the enabled button fires:

```swift
services.intents.execute(
    id: "global.review.pr",
    params: ["url": .string(currentPRURL)]
)
```

This opens or re-focuses the code-review patrol session for that PR via
`PatrolOpener.openReusingWorktree` and `SessionFactory.createPatrolSession`.

## Shared storage namespace: github/prs

The `github` (session) widget uses the `github` storage namespace. The key
`github/prs` holds a JSON array of PR objects:

```json
[
  {
    "url":       "https://github.com/owner/repo/pull/N",
    "status":    "open | merged | closed",
    "merged_at": "ISO-8601 timestamp or null"
  }
]
```

The `github-prs` Home widget does **not** use this key — it discovers repos
from the workspace root via shell.

Agents can read or write `github/prs` directly via the CLI:

```bash
# Read attached PRs on a task
task42 storage get <task-id> github/prs

# Attach a PR without the widget open
task42 storage set <task-id> github/prs \
  '[{"url":"https://github.com/owner/repo/pull/42","status":"open","merged_at":null}]'

# On a patrol session
patrol42 storage get <patrol-id> github/prs
patrol42 storage set <patrol-id> github/prs \
  '[{"url":"https://github.com/owner/repo/pull/42","status":"open","merged_at":null}]'
```

## [system event] delivery

The `github` widget delivers PR activity as `[system event]`s using
`task42 event` (task sessions) or `patrol42 event` (patrol sessions). Each
event carries a fingerprint so `pending_updates` deduplicates repeat deliveries
automatically — even across widget restarts and app relaunches.

| Event | Fingerprint | Trigger |
|-------|-------------|---------|
| Review submitted | `review:<reviewId>` | New review entry from `gh pr view` |
| Issue comment | `comment:<commentId>` | New PR comment |
| Inline review comment | `review-comment:<commentId>` | New entry from `gh api …/comments` |
| CI check failed | `check:<checkName>:<conclusion>` | Check completes with failing conclusion |
| All CI green | `checks:all-green:<name1,name2,…>` | All checks pass |
| PR merged | `state:merged:<prNumber>` | `state == MERGED` (idempotent, every poll) |
| PR closed | `state:closed:<prNumber>` | `state == CLOSED` (idempotent, every poll) |
| PR reopened | `state:reopened:<prNumber>` | State transitions back to OPEN |

On the first poll of a fresh agent instance, the agent seeds the current
fingerprint set in memory (no delivery). This suppresses replay of events that
already happened before the agent started on this session. Stopping and
restarting the agent (dormancy + session coming alive again, or `work42 widget
reload`) resets the baseline; `ON CONFLICT DO NOTHING` prevents re-delivery of
events already in `pending_updates`.

## global.review.pr intent

The `global.review.pr` palette intent accepts a PR URL and opens (or
re-focuses) the code-review session for that PR. Widgets fire it with:

```swift
services.intents.execute(id: "global.review.pr", params: ["url": prURL])
```

The host handler calls `PatrolOpener.openReusingWorktree` and
`SessionFactory.createPatrolSession`, then opens the session in Chat. The
result is indistinguishable from clicking "Review a PR" in the command palette
and pasting the URL — but fully automated from the `github-prs` action-center
button.

## Tab template: GitHub Review

The plugin ships a **GitHub Review** tab template (UUID
`1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d`) that opens `widget:github-prs` on
the Home surface. Open it from the ⌘⇧T picker once the plugin is installed.

## gh availability (github widget only)

`gh` must be installed and authenticated (`gh auth login`) for the **`github`**
session widget to poll for events. The `github-prs` Home widget uses only `git`
and does not require `gh`.

If `gh` is unavailable or unauthenticated, `GitHubBackgroundAgent` skips the
affected PR for that poll cycle and retries on the next one — no error banner is
shown, no crash occurs. The browser surface remains accessible for already-
attached PRs; the empty-state form shows a neutral "No PR yet" prompt regardless
of `gh` availability.

## Installation

```bash
work42 plugin install /path/to/work42-plugins/github
```

The plugin installs the `github` and `github-prs` widgets, symlinks the widget
and plugin skills into `~/.claude/skills/`, and registers the GitHub Review tab
template so it appears in the ⌘⇧T picker.

The `jira` and `github` plugins are also bundled inside the Work42 app and
auto-installed on first launch via `PrebuiltPluginMaterializer` — you only need
the manual install step for modified copies or development builds.
