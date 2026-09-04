---
name: widget-jira
description: |
  How to use the Jira widget (session tab kindId widget:jira).
  This widget shows the Jira issue linked to the current session (task or
  code review). It reads and writes the session's storage namespace: jira/url
  (full issue URL), jira/key (e.g. "PROJ-123"). Use
  `task42 storage set <id> jira/url "<url>"` on a task, to attach a Jira
  issue without the widget open. The widget is installed by default; the
  user can opt out via the My Widgets settings panel.
---

# Jira widget

Renders the Jira issue linked to the current session inside Work42. Sign in
once anywhere in a browser-based widget (Browser, GitHub PR, or here) and
the login persists across all of them and across restarts — they share one
cookie jar (`dataStoreKey: "browser"`).

## Storage convention

| Key | Type | Description |
|-----|------|-------------|
| `jira/url` | string | Full Jira issue URL (e.g. `https://myorg.atlassian.net/browse/PROJ-123`) |
| `jira/key` | string | Parsed issue key (e.g. `PROJ-123`) — set automatically on URL write |

The widget reads `jira/url` on mount. If absent it shows a paste-URL empty
state; if present it renders the issue in a browser surface with the shared
`"browser"` login cookie jar.

## Agent usage

```bash
# Attach a Jira issue to the current task
task42 storage set <task-id> jira/url '"https://myorg.atlassian.net/browse/PROJ-123"'

# Read the stored key (set automatically by the widget on URL write)
task42 storage get <task-id> jira/key
# → "PROJ-123"

# Clear the ticket (returns widget to paste-URL form)
task42 storage delete <task-id> jira/url
task42 storage delete <task-id> jira/key
```

## URL shapes supported

The widget accepts any Atlassian Cloud URL that contains a Jira issue key
(`[A-Z][A-Z0-9]+-[0-9]+`) in its path. All of these work:

- `https://myorg.atlassian.net/browse/PROJ-123`
- `https://myorg.atlassian.net/issues/PROJ-123`
- `https://myorg.atlassian.net/jira/software/projects/PROJ/issues/PROJ-123`

## Header chips and Atlassian CLI

The widget's background agent always publishes a Jira-branded issue-key segment.
Every 60 seconds it also runs:

```bash
acli jira workitem view PROJ-123 --fields status,labels --json
```

When `acli` is installed, authenticated, and returns parseable JSON, the chip
group becomes **key • status • labels**. If the CLI is missing, logged out,
errors, or returns unexpected data, the widget silently keeps the key-only chip;
the browser widget remains usable and no error banner is shown. Use the
plugin-level `using-jira-cli` skill for installation and authentication.

## Widget lifecycle

- **Empty state**: paste-URL form → on submit, writes `jira/url` + `jira/key`
  via `services.storage.set(key:value:)` (own namespace `jira`).
- **Assigned state**: full-page BrowserSurface with a "Change ticket" button
  to clear storage and return to the empty state.
- **Deactivate**: tears down the browser cache; storage is persistent.
