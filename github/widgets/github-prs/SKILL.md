---
name: widget-github-prs
description: |
  How to use the github-prs widget (session tab kindId widget:github-prs).
  This widget lists the current user's open GitHub pull requests (via
  `gh pr list --author @me`) and renders one row per PR with a
  "Start code review session" button. Clicking the button fires the
  global.review.pr palette intent with the PR URL, opening or re-focusing
  that PR's code-review session in one click. Requires the GitHub CLI (`gh`)
  to be installed and authenticated.
---

# GitHub PRs widget

## Overview

The `github-prs` widget is a native list view that:

- Fetches the **current user's open pull requests** on activate and on manual
  refresh via `gh pr list --author @me --state open --json number,title,url,headRefName,repository --limit 50`.
- Renders **one row per PR** showing: repository name, PR number, PR title,
  and branch name.
- Provides a **"Start code review session"** button on every row that fires
  the `global.review.pr` palette intent with that PR's URL, opening (or
  re-focusing) the code-review session in one click.
- Shows a **friendly empty card** when you have no open PRs.
- Shows a **fail-loud error card** with a named remedy when `gh` is missing or
  unauthenticated — never a blank tile.
- Exposes a **Refresh** intent (palette + action-area icon button) to re-run
  the fetch on demand. No background polling.

## Requirements

| Requirement | Details |
|---|---|
| GitHub CLI | `brew install gh` |
| Authentication | `gh auth login` |
| Scope | Reads public + private repos accessible to the authenticated user |

The widget will show an error card with the exact remedy command if `gh` is not
installed or not authenticated.

## Row layout

Each PR row displays:
- **Eyebrow** — `owner/repo #number`
- **Title** — the PR title (wraps up to two lines)
- **Branch** — `headRefName` (the source branch)
- **Button** — "Start code review session"

## Session launch

The "Start code review session" button calls:

```
services.intents.execute(id: "global.review.pr", params: ["url": .string(prURL)])
```

The host intent opens or re-focuses the patrol session for that PR's URL, reusing
`PatrolOpener.openReusingWorktree` and `SessionFactory.createPatrolSession`.

## Refresh

Three ways to refresh the PR list:

1. **Action-area button** — the `↻` icon button in the tab-bar row beside the
   widget title.
2. **Header button** — the `↻` button inside the widget's own header row.
3. **Command palette** — search "Refresh PR List" (`⌘⇧P`).

## No storage dependency

This widget does NOT read or write `github/prs` storage. It fetches live from
GitHub on every refresh. The existing `github` widget and the `github-prs`
widget are independent — both can be open in the same session.

## Agent usage

Agents do not need to call this widget directly. To look up a user's open PRs
programmatically, run:

```bash
gh pr list --author @me --state open --json number,title,url,headRefName,repository --limit 50
```

To trigger a code-review session from an agent, call:

```bash
task42 palette execute global.review.pr --param url=<PR_URL>
```

(If the `task42 palette execute` command is available in the project's CLI
version; otherwise use the widget's button or the palette directly.)
