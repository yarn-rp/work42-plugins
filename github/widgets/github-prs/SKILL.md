---
name: widget-github-prs
description: |
  How to use the github-prs widget (widget id: github-prs). This widget
  renders one browser tab per git repository found in the workspace root,
  opening each repo's GitHub pull-requests page
  (https://github.com/<owner>/<repo>/pulls). It lives on the Home surface.
  A GitHub-branded "Review GitHub PR" action-center button is enabled when the
  active browser tab is viewing a specific PR page (/pull/<N>). It resolves
  the PR to GitHub's stable pull-request head ref and fires the typed
  session.open.codeReview intent. Starting a review uses git remote access;
  it does not require the gh CLI.
---

# GitHub PRs widget

## Overview

The `github-prs` widget is a **Home-surface browser widget** that:

- Enumerates **git repositories** in the workspace root via `git` (no gh CLI).
- Opens **one browser tab per repo** at its GitHub pull-requests page:
  `https://github.com/<owner>/<repo>/pulls`.
- Shows a **fail-loud error card** when no GitHub repos are found or when git
  is unavailable — never a blank tile.
- Exposes a **"Review GitHub PR"** button in the **action center**
  that appears ONLY when the active browser tab is viewing a specific PR page
  (URL path matches `/pull/<N>`). Clicking it resolves the stable PR head ref and
  fires `session.open.codeReview` with typed arguments.

## Placement

**Home surface only.** The widget relies on `services.shell` running with cwd
set to the workspace root, which is guaranteed only on the Home surface. It
will not appear in the `+ Widget` menu on session, task, or meeting surfaces.

## Repo enumeration

On activation, the widget runs a shell script in the workspace root:

1. If the root itself has a `.git` directory, it is used as the single repo.
2. Otherwise, every immediate subdirectory with a `.git` directory is picked up
   (the standard Work42 multi-repo workspace layout).

For each git repo found, the widget reads `remote.origin.url` via:

```bash
git -C <dir> config --get remote.origin.url
```

The URL is parsed for the GitHub owner/repo (SSH shorthand, HTTPS, and SSH
explicit forms are all supported). The resulting PRs-page URL is:

```
https://github.com/<owner>/<repo>/pulls
```

## Requirements

| Requirement | Details |
|---|---|
| `git` | Must be installed and in PATH (Homebrew: `/opt/homebrew/bin/git`) |
| GitHub remote | Each workspace repo must have `remote.origin.url` pointing to GitHub |
| Browser sign-in | Sign in to GitHub once in the embedded browser; the session is shared across all GitHub browser widgets (`dataStoreKey: "github"`) |

Browsing and starting a review use `git`. Launch passes
`refs/pull/<number>/head`, which also works for fork pull requests.

## Tabs

The widget renders **one browser tab per workspace repo**. The tab title is
`owner/repo`. Switching between tabs shows different repos' PR lists.

## Action-center button — “Review GitHub PR”

The button appears in the **action center** (beside `+ Add Widget`) when this
widget is active in the current tab. It is:

- **Enabled** when the active tab's URL is a GitHub PR page
  (path matches `/owner/repo/pull/<N>`, e.g. `.../pull/42`).
- **Dimmed-but-visible** when the active tab is showing a PR list or any
  other GitHub page.

Clicking the enabled button resolves the stable PR head ref, maps the GitHub repo
to its workspace repository key, and fires:

```swift
services.intents.execute(
    id: "session.open.codeReview",
    params: [
        "kind": .string("codeReview"),
        "codeReview": .object(["branchesByRepository": .object([repoKey: .string("refs/pull/<number>/head")])]),
        "initialWidgetStorage": .object(["github": .object(["prs": prMetadata])]),
    ]
)
```

This opens a provider-neutral Code Review session on the PR branch and seeds
the session-scoped GitHub widget metadata.

## Error card

If enumeration fails (git not found, no repos, no GitHub remote), a
fail-loud card is shown with:

- A warning icon
- A human-readable error message with the specific cause
- A **Retry** button that re-runs enumeration

## Session metadata

This Home widget discovers repositories fresh on every activation and does not
use Home storage. When it starts a review, it seeds `github/prs` in the new
session's widget storage so the separate `github` session widget can render and
monitor the selected PR.

## Agent usage

Agents do not call this widget directly. To enumerate workspace repos:

```bash
# At the workspace root:
for d in $(ls -d */); do
  if [ -d "${d}.git" ]; then
    url=$(git -C "${d%/}" config --get remote.origin.url 2>/dev/null)
    echo "${d%/}: $url"
  fi
done
```

To trigger a code-review session from an agent after resolving the workspace
repository key and branch:

```bash
task42 palette execute session.open.codeReview \
  --params '{"kind":"codeReview","codeReview":{"branchesByRepository":{"<repo-key>":"origin/<branch>"}}}'
```
