---
name: using-jira
description: |
  How to use the Work42 Jira plugin together: the jira issue browser widget
  (session-scoped, jira/url storage) and the jira-my-issues Home-surface board
  browser widget (paste-URL-once, project-scoped storage, no API token). Covers
  the board URL persistence via the Home storage backend, the action-center
  "Start task session" button (enabled on /browse/ URLs), and the typed
  session.open.task intent it fires. Install with:
  work42 plugin install <path-to-jira-plugin>
---

# Using the Jira plugin

The Jira plugin ships two complementary widgets that together give you full
issue workflow coverage inside Work42.

For agent-driven Jira reads and writes, use the companion
`using-jira-cli` skill. It uses Atlassian's official `acli` for view, search,
label edits, transitions, and comments, and is preferred over the Atlassian
Rovo MCP connector.

## The two widgets

### widget:jira — issue browser (session-scoped)

The `jira` widget renders the Jira issue linked to the current session as a
full-page browser surface. Two states:

- **Empty state**: a paste-URL form. On submit, the widget parses the Jira
  issue key from the URL and writes both `jira/url` and `jira/key` to the
  session's `jira` storage namespace.
- **Assigned state**: renders the issue in a `BrowserSurface` with a "Change
  ticket" button to return to the empty state.

The browser surface shares the `"browser"` cookie jar (`dataStoreKey:
"browser"`) with the built-in Browser widget — sign in to Jira once anywhere
and the login persists across all browser-based widgets and app restarts.

Use this widget in a **task session** where you are working on a specific Jira
issue.

### widget:jira-my-issues — Home-surface board browser

The `jira-my-issues` widget is a **Home-surface board browser widget**. On
first activation it shows a paste-URL empty state — paste any Jira board URL
and click **Pin board**. The URL is validated and persisted to the
project-scoped Home storage backend (key `jira-my-issues/board`).

**No API token, email, or credential form.** Authentication is through the
embedded browser (`dataStoreKey: "browser"`) — sign in to Jira once and the
session persists across restarts (shared with the `jira` widget).

Use this widget on the **Home surface** to keep your Jira board always one
click away.

**Action-center button — "Start task session"**

The button appears in the action center while `jira-my-issues` is active. It is:

- **Enabled** when the browser's current URL contains `/browse/` (a Jira issue
  page, e.g. `https://myorg.atlassian.net/browse/PROJ-123`).
- **Dimmed but visible** when the browser is on the board itself or any other
  page.

Its enabled state is driven by `WidgetIntentSpec.isEnabled` — a render-time
closure that reads the current URL from the widget's `BrowserWidgetModel`.

Clicking the enabled button fires the typed session intent, naming the task
after the issue key parsed from the URL:

```swift
services.intents.execute(
    id: "session.open.task",
    params: [
        "kind": .string("task"),
        "task": .object(["name": .string("<ISSUE-KEY>"), "kind": .string("feature")]),
        "initialWidgetStorage": .object(["jira": .object(["url": .string(currentIssueURL)])]),
    ]
)
```

This creates a task session titled with the issue key, seeded with that
issue's `jira/url`, and opens it with the `jira` widget pre-loaded to the
issue. Session-creation failures stay visible in Work42's blocking error
dialog.

## Storage

### Session widget (jira): task-scoped storage

| Key | Type | Description |
|-----|------|-------------|
| `jira/url` | string | Full Jira issue URL (e.g. `https://myorg.atlassian.net/browse/PROJ-123`) |
| `jira/key` | string | Parsed issue key (e.g. `PROJ-123`) — set automatically on URL write |

The `jira` widget reads and writes `jira/url` and `jira/key` via
`services.storage` in the session's `jira` namespace.

Agents can read or write these keys directly via the CLI:

```bash
# Attach a Jira issue to a task
task42 storage set <task-id> jira/url '"https://myorg.atlassian.net/browse/PROJ-123"'

# Read the auto-parsed key
task42 storage get <task-id> jira/key
# → "PROJ-123"

# Clear the ticket (returns widget to paste-URL form)
task42 storage delete <task-id> jira/url
task42 storage delete <task-id> jira/key
```

### Home widget (jira-my-issues): project-scoped Home storage

| Key | Type | Description |
|-----|------|-------------|
| `jira-my-issues/board` | string | The pinned Jira board URL |

The board URL is persisted to the **project-scoped Home storage backend**
(`ProjectStorageBackend`), backed by
`~/.work42/task42/projects/<slug>/home-widget-storage.json`. It is remembered
per project and survives app restarts.

To clear the board URL and return the widget to the empty-state form, click
**Change board** in the widget.

## session.open.task intent

The typed `session.open.task` intent creates a task session from structured
arguments: the task `name`/`kind`, and opaque `initialWidgetStorage` the host
persists into the task's storage without interpreting it. The host runs the
equivalent of:
```bash
task42 create --name "PROJ-123" --type task --storage jira/url=<url>
```
then opens the new session in Chat. The result is a fully initialized task
session with the `jira` widget already pointed at the issue.

## URL shapes supported

The `jira` widget accepts any Atlassian Cloud URL that contains a Jira issue
key (`[A-Z][A-Z0-9]+-[0-9]+`) in its path:

- `https://myorg.atlassian.net/browse/PROJ-123`
- `https://myorg.atlassian.net/issues/PROJ-123`
- `https://myorg.atlassian.net/jira/software/projects/PROJ/issues/PROJ-123`

## Tab template: Jira Work

The plugin ships a **Jira Work** tab template (UUID
`2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e`) that opens `widget:jira-my-issues` on
the Home surface. Open it from the ⌘⇧T picker once the plugin is installed.

## Authentication notes

- **jira (session) widget**: uses the shared `"browser"` cookie jar — sign in
  to Jira in any browser-based widget once and it persists. No API token needed.
- **jira-my-issues (Home) widget**: uses the same shared `"browser"` cookie jar.
  No API token, email, or credential form. Authentication is entirely
  browser-based.

## Installation

```bash
work42 plugin install /path/to/work42-plugins/jira
```

The plugin installs into `~/.work42/plugins/jira/` (its widgets + skills);
sessions pick up its widgets and skills automatically — they self-compose
from the installed plugins, so there is no symlink into `~/.claude/skills/`
(that legacy global-install model was retired). It also registers the Jira
Work tab template so it appears in the ⌘⇧T picker.

The `jira` and `github` plugins are also bundled inside the Work42 app and
auto-installed on first launch via `PrebuiltPluginMaterializer` — you only need
the manual install step for modified copies or development builds.
