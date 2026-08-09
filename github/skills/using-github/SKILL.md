---
name: using-github
description: |
  How to use the Work42 GitHub plugin together: the github PR browser widget
  and the github-prs list widget. Covers the shared storage namespace
  (github/prs), the [system event] delivery scheme, the github-prs list with
  its Start code review session button, and the global.review.pr palette
  intent. Install this plugin with: work42 plugin install <path-to-github-plugin>
---

# Using the GitHub plugin

The GitHub plugin ships two complementary widgets that together give you full
PR workflow coverage inside Work42.

## The two widgets

### widget:github — PR browser

The `github` widget renders one embedded browser tab per pull request attached
to the current session. It runs a 60-second background watch loop via
`services.shell` that polls each PR with `gh pr view` and `gh api …/comments`,
then delivers new activity (reviews, comments, CI checks, merge/close) as
fingerprinted `[system event]`s so the agent is always aware of PR activity.

Use this widget in a **task session** or a **patrol code-review session** where
you know which specific PR you are working on.

### widget:github-prs — open PRs list

The `github-prs` widget runs `gh pr list --author @me --json number,title,url,headRefName`
to fetch all of your currently open pull requests and renders one row per PR.
Each row shows the PR title, repository, and a **Start code review session**
button.

Clicking **Start code review session** on a row executes the palette intent
`global.review.pr` with that PR's URL. Work42 then opens (or re-focuses) a
code-review patrol session for that PR, with the `github` widget pre-seeded
with the PR URL so the browser and watch loop start immediately.

Use this widget on the **Home surface** or in an unbound (plain) session as a
dashboard for all your in-flight PRs.

## Shared storage namespace: github/prs

Both widgets share the `github` storage namespace. The key `github/prs` holds
a JSON array of PR objects:

```json
[
  {
    "url":       "https://github.com/owner/repo/pull/N",
    "status":    "open | merged | closed",
    "merged_at": "ISO-8601 timestamp or null"
  }
]
```

The `github` widget reads and writes this key via `services.storage` (its own
writable namespace, since widget id == storage namespace == `"github"`).
The `github-prs` widget reads it for real-time status badges alongside the
`gh pr list` output when the user is in a session context.

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

The first time the widget observes a PR it seeds the current fingerprint set in
memory (no delivery). This suppresses replay of events that already happened
before the widget was first opened on this session.

## global.review.pr intent

The `global.review.pr` palette intent accepts a PR URL and opens (or
re-focuses) the code-review session for that PR. Widgets fire it with:

```swift
services.intents.execute(id: "global.review.pr", params: ["url": prURL])
```

The host handler calls `PatrolOpener.openReusingWorktree` and
`SessionFactory.createPatrolSession`, then opens the session in Chat. The
result is indistinguishable from clicking "Review a PR" in the command palette
and pasting the URL — but fully automated from the `github-prs` list row.

## Tab template: GitHub Review

The plugin ships a **GitHub Review** tab template (UUID
`1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d`) that opens both widgets in one tab:
`widget:github-prs` in the left column and `widget:github` in the right. Open
it from the ⌘⇧T picker once the plugin is installed.

## gh availability

`gh` must be installed and authenticated (`gh auth login`) for both widgets to
work. If `gh` is unavailable or unauthenticated:

- `github` widget: shows a banner ("gh unavailable: …") in the empty state;
  the browser surface is still accessible for any already-attached PRs.
- `github-prs` widget: shows a named error state ("gh unavailable — run gh
  auth login") rather than a blank tile.

Neither widget crashes or silently fails — degradation is always visible.

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
