---
name: widget-github
description: |
  How to use the GitHub PR widget (session tab kindId widget:github).
  This widget renders one browser tab per PR attached to the current session
  (task or patrol) and runs a background watch loop. It reads and writes the
  session's storage namespace: github/prs (JSON array of {url, status,
  merged_at}). Use `task42 storage set <id> github/prs '<json>'` on a task,
  or `patrol42 storage set <id> github/prs '<json>'` on a patrol, to attach
  PRs without the widget open. The widget delivers PR activity as
  `[system event]`s via `task42 event` / `patrol42 event`. The widget is
  installed by default; the user can opt out via the My Widgets settings
  panel.
---

# GitHub PR widget

## Overview

The `github` pre-built widget is a BrowserSurface-based multi-tab view that:

- Renders **one browser tab per PR** from the `github/prs` storage array.
- Runs a **60-second background poll loop** inside `GitHubBackgroundAgent`, a
  per-(session × widget) `WidgetBackgroundAgent` managed by `WidgetBackgroundHost`.
  The loop runs while the session's ACP runner is alive and the widget is in the
  session's saved layout — **independently of whether the session panel is open**.
  The view (`activate`) handles browser model, selection state, and
  `BrowserSurfaceCache` teardown only; it refreshes its PR tabs from storage on
  each `activate` call (`loadAndSyncPRs`).
- Delivers new PR activity as fingerprinted `[system event]`s via `task42 event`
  (task sessions) or `patrol42 event` (patrol sessions).
- Provides an **empty-state form** for paste-URL attach and a **+ button** for
  subsequent attaches when one or more tabs are already open.
- Updates `status` and `merged_at` fields in `github/prs` automatically when a
  PR is merged or closed.

If `gh` is missing or unauthenticated the agent skips that PR for the cycle and
retries on the next poll — no banner is shown, no crash occurs.

## Storage convention

| Key | Namespace | Description |
|-----|-----------|-------------|
| `github/prs` | `github` | JSON array of `{url, status, merged_at}` — one entry per attached PR |

### PR object schema

```json
{
  "url":       "https://github.com/owner/repo/pull/N",
  "status":    "open | merged | closed",
  "merged_at": "ISO-8601 timestamp or null"
}
```

## Agent usage

```bash
# Read the attached PRs
task42 storage get <task-id> github/prs

# Attach a PR (without the widget open)
task42 storage set <task-id> github/prs \
  '[{"url":"https://github.com/owner/repo/pull/42","status":"open","merged_at":null}]'

# Attach multiple PRs
task42 storage set <task-id> github/prs \
  '[{"url":"https://github.com/owner/repo/pull/42","status":"open","merged_at":null},
    {"url":"https://github.com/owner/repo/pull/43","status":"open","merged_at":null}]'

# Check merge discipline before `task42 accept`
task42 storage get <task-id> github/prs | jq '[.[] | select(.status != "merged")] | length'
# Must be 0 for a clean Done transition
```

### On a patrol (code-review) session

Identical convention, `patrol42 storage` instead of `task42 storage`:

```bash
patrol42 storage get <patrol-id> github/prs
patrol42 storage set <patrol-id> github/prs \
  '[{"url":"https://github.com/owner/repo/pull/42","status":"open","merged_at":null}]'
```

## Events delivered

The widget delivers the following `[system event]`s via `task42 event` (task
sessions) or `patrol42 event` (patrol sessions) — same fingerprint scheme,
same dedup ledger, whichever session kind the widget is hosted in. Every
event carries a **fingerprint** so `pending_updates` deduplicates repeat
deliveries automatically — even across widget restarts.

| Event | Fingerprint | Trigger |
|-------|-------------|---------|
| Review submitted | `review:<reviewId>` | New `gh pr view` review entry |
| Issue comment | `comment:<commentId>` | New PR comment |
| Inline review comment | `review-comment:<commentId>` | New `gh api …/comments` entry |
| CI check failed | `check:<checkName>:<conclusion>` | Check completes with a failing conclusion |
| All CI green | `checks:all-green:<name1,name2,…>` | All checks complete with passing conclusions |
| PR merged | `state:merged:<prNumber>` | `state == MERGED` (runs every poll; idempotent) |
| PR closed | `state:closed:<prNumber>` | `state == CLOSED` (runs every poll; idempotent) |
| PR reopened | `state:reopened:<prNumber>` | `state` transitions back to OPEN |

### Fingerprint compatibility note

These fingerprints match the scheme used by the now-deleted `PRWatchService`
(removed in `feat/generalizations-of-features.8`). Existing `pending_updates`
rows from PRWatchService carry these fingerprints, so `ON CONFLICT DO NOTHING`
prevents re-delivery on tasks that were previously tracked by that service.

### Baseline seeding

On the **first observation** of a PR by a fresh agent instance, the agent
computes the current fingerprint set and stores it in memory WITHOUT calling
`task42 event`. This suppresses delivery of events that already happened before
the agent was started on this session.

Stopping and restarting the agent (dormancy expiry + session becoming alive
again, layout removal + re-add, or `work42 widget reload`) resets the in-memory
baseline. Since `task42 event` uses `ON CONFLICT DO NOTHING`, events that were
delivered during a previous agent run will not be re-delivered; events that were
only baseline-seeded may fire on the next start.

### Terminal state self-healing

The `state:merged` and `state:closed` fingerprints are delivered on **every
poll** when the PR is in a terminal state. The `ON CONFLICT DO NOTHING` in
`pending_updates` makes this idempotent — the event delivers at most once.
This ensures a merge event is never permanently missed due to a transient
network or gh failure during the poll that originally observed the merge.

## Message format

Each event message is prefixed with the PR identity:

```
PR <owner>/<repo>#<N>: <event description>
```

Examples:
- `PR octo/app#42 review by @alice: APPROVED — "LGTM, nice work"`
- `PR octo/app#42 comment from @bob: "Could we add a test for this?"`
- `PR octo/app#42 CI failed: build (failure) — push a fix and CI will re-run.`
- `PR octo/app#42 CI is all green — 4 checks passed.`
- `PR octo/app#42 was merged.`
