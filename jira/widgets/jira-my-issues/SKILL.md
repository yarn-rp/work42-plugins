---
name: widget-jira-my-issues
description: |
  How to use and configure the jira-my-issues widget (widget kindId
  widget:jira-my-issues). This widget pins the user's Jira board URL in a
  full-page BrowserSurface on the Home surface. No API token or email is
  required — authentication is through the shared browser session (dataStoreKey
  "browser"). The board URL is entered once via an empty-state form and persisted
  to project-level Home storage (key jira-my-issues/board). A "Start Task
  Session" button appears in the action area ONLY when the browser is viewing a
  Jira issue page (URL path contains /browse/).
---

# jira-my-issues widget

Pins the user's Jira board URL in a BrowserSurface so the board is always one
click away from the Home surface. Sign in to Jira once via the browser; the
cookie session persists across restarts (shared dataStoreKey `"browser"`).

## Setup

On first use, the widget shows a paste-URL form. Paste any Jira board URL (e.g.
`https://myorg.atlassian.net/jira/software/projects/PROJ/boards`) and click
**Pin board**. The URL is validated and written to storage. Subsequent activations
go directly to the board.

**No API token or email/credential form** — authentication is through the
embedded browser. Sign in to Jira the first time you open the widget; the session
is kept automatically.

## Storage key

| Full address | Type | Description |
|---|---|---|
| `jira-my-issues/board` | string | The pinned Jira board URL. |

The key lives in the widget's own namespace (`jira-my-issues`). On the Home
surface it is backed by the project-level `home-widget-storage.json` file
(`~/.work42/task42/projects/<slug>/home-widget-storage.json`). On a task session
it is backed by `task_storage` (per-task).

Read from any namespace:
```swift
services.storage.get(namespace: "jira-my-issues", key: "board")
```

Write (from the widget's own storage surface):
```swift
services.storage.set(key: "board", value: .string(boardURL))
```

## Editing or removing the board URL

Click **Edit board** in the bottom-right of the widget while the board is open.
The editor opens with the current URL pre-filled. Change it and click **Save
board**; the new value is validated and replaces `jira-my-issues/board` only
after a successful save. A validation or persistence error leaves the previous
board untouched and displays an inline error.

Use the separate destructive **Remove board** action in that editor only when
you want to clear the stored URL and return to the first-use paste form.

Alternatively, from the CLI:
```bash
# Set a new board URL (JSON-encoded string)
task42 storage set <task-id> jira-my-issues/board '"https://myorg.atlassian.net/jira/software/projects/PROJ/boards"'

# Clear the stored URL (returns widget to the empty-state form)
task42 storage delete <task-id> jira-my-issues/board
```

## Widget lifecycle

1. **Empty state** — shown on first use (no URL stored). Presents a text field
   for the board URL. On submit the URL is validated and written to storage;
   the widget transitions immediately to the Board state.

2. **Loading** — a brief spinner while the stored URL is read from storage on
   activate. Prevents flashing the empty-state form before the URL loads.

3. **Board state** — `BrowserSurface` rendering the pinned Jira board. The full
   page is shown (no CSS selector isolation). An **Edit board** button is always
   visible in the bottom-right corner; it opens a pre-filled editor with a
   separate **Remove board** action.

## "Start Task Session" action-area button

A **Start Task Session** button appears in the tab action-area bar (and in the
command palette under `widget.jira-my-issues.start-task-session`) when the Jira
board browser is open. The button is:

- **Enabled** only when the browser's current URL contains `/browse/` — i.e. the
  user has navigated from the board to a specific Jira issue page
  (e.g. `https://myorg.atlassian.net/browse/PROJ-123`).
- **Dimmed** when the browser is on the board itself or any other page.

When clicked (or executed from the palette), the button fires the typed
session intent, naming the task after the issue key parsed from the URL:
```
services.intents.execute(
  id: "session.open.task",
  params: [
    "kind": .string("task"),
    "task": .object(["name": .string("<ISSUE-KEY>"), "kind": .string("feature")]),
    "initialWidgetStorage": .object(["jira": .object(["url": .string(currentURL)])]),
  ]
)
```

This creates a task session titled with the issue key (e.g. `PROJ-123`),
seeds `jira/url` into the task's storage so the Jira widget pre-loads that
issue, and shows the host's blocking loading → error overlay while the
session is set up.

## Browser login

The widget uses `dataStoreKey: "browser"` — the same persistent cookie store as
the built-in Browser and Jira widgets. Signing in to Jira in any one of these
surfaces keeps the session for all of them. There is no separate login for the
board widget.
