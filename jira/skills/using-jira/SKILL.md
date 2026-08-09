---
name: using-jira
description: |
  How to use the Work42 Jira plugin together: the jira issue browser widget
  and the jira-my-issues list widget. Covers the shared storage namespace
  (jira/url, jira/key, jira/base, jira/email, jira/token), the
  jira-my-issues list with its Start work session button, and the
  global.new.task palette intent. Install with:
  work42 plugin install <path-to-jira-plugin>
---

# Using the Jira plugin

The Jira plugin ships two complementary widgets that together give you full
issue workflow coverage inside Work42.

## The two widgets

### widget:jira — issue browser

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

### widget:jira-my-issues — assigned issues list

The `jira-my-issues` widget fetches all issues assigned to the current user via
the Jira REST API (`jql=assignee=currentUser()`) and renders one row per issue.
Each row shows the issue key, summary, status, and a **Start work session**
button.

Clicking **Start work session** on a row executes the palette intent
`global.new.task` with that issue's URL. Work42 then creates a new task session
seeded with that issue's `jira/url` and `jira/key`, equivalent to running
`task42 create --storage jira/url=<url>`.

Use this widget on the **Home surface** or in an unbound session as a dashboard
for all your assigned Jira issues.

## Storage namespace: jira

Both widgets share the `jira` storage namespace. Key schema:

| Key | Type | Description |
|-----|------|-------------|
| `jira/url` | string | Full Jira issue URL (e.g. `https://myorg.atlassian.net/browse/PROJ-123`) |
| `jira/key` | string | Parsed issue key (e.g. `PROJ-123`) — set automatically on URL write |
| `jira/base` | string | Atlassian domain (e.g. `myorg.atlassian.net`) — used by `jira-my-issues` |
| `jira/email` | string | Atlassian account email — used by `jira-my-issues` for Basic Auth |
| `jira/token` | string | Atlassian API token — used by `jira-my-issues` for REST API calls |

The `jira` widget reads and writes `jira/url` and `jira/key` via
`services.storage` (its own writable namespace, since widget id ==
storage namespace == `"jira"`).

The `jira-my-issues` widget reads `jira/base`, `jira/email`, and `jira/token`
from the same `jira` namespace. When any of these are missing, it shows a
named empty-state setup form rather than a silent blank tile.

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

# Set credentials for jira-my-issues (stored in the jira namespace globally)
task42 storage set <task-id> jira/base '"myorg.atlassian.net"'
task42 storage set <task-id> jira/email '"user@example.com"'
task42 storage set <task-id> jira/token '"your-api-token"'
```

### Generating an API token

The `jira-my-issues` widget requires an Atlassian API token (not your password).
Generate one at: https://id.atlassian.com/manage-profile/security/api-tokens

The token is stored as a plain string in the widget's storage namespace. It is
not transmitted beyond the local Jira REST API call made via `services.shell`.

## global.new.task intent

The `global.new.task` palette intent accepts a Jira issue URL and creates (or
re-opens) a task session seeded with that issue. Widgets fire it with:

```swift
services.intents.execute(id: "global.new.task", params: ["jiraURL": issueURL])
```

The host handler runs the equivalent of:
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
`2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e`) that opens both widgets in one tab:
`widget:jira-my-issues` in the left column and `widget:jira` in the right.
Open it from the ⌘⇧T picker once the plugin is installed.

## Authentication notes

- **jira (browser) widget**: uses the shared `"browser"` cookie jar — sign in
  to Jira in any browser-based widget once and it persists. No API token
  needed.
- **jira-my-issues widget**: uses Atlassian Basic Auth (email + API token) for
  the REST search endpoint. The browser cookie is not sufficient for REST calls,
  so a token is required. The setup form guides you through entering it.

If credentials are missing or invalid, `jira-my-issues` shows a named error
state ("Missing Jira credentials — tap to set up") rather than a silent blank.

## Installation

```bash
work42 plugin install /path/to/work42-plugins/jira
```

The plugin installs the `jira` and `jira-my-issues` widgets, symlinks the
widget and plugin skills into `~/.claude/skills/`, and registers the Jira Work
tab template so it appears in the ⌘⇧T picker.

The `jira` and `github` plugins are also bundled inside the Work42 app and
auto-installed on first launch via `PrebuiltPluginMaterializer` — you only need
the manual install step for modified copies or development builds.
