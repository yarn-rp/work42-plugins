---
name: widget-jira-my-issues
description: |
  How to use and configure the jira-my-issues widget (session tab kindId
  widget:jira-my-issues). This widget lists the current user's assigned Jira
  issues (fetched via the Jira REST API using a stored API token) and provides
  one-click "Start work session" buttons per issue row. Configure it by setting
  three storage keys in the widget's own namespace: jira-my-issues/base,
  jira-my-issues/email, and jira-my-issues/token. Use
  `task42 storage set <task-id> jira-my-issues/<key> "<json-value>"` to set
  credentials from the CLI without the widget UI open.
---

# jira-my-issues widget

Lists all Jira issues assigned to the current user whose status category is not
Done. One row per issue; each row shows the issue key, summary, and status, plus
a "Start work session" button that fires the `global.new.task.jira` palette
intent with the issue URL — opening (or re-focusing) a task session seeded with
that issue.

This widget uses an Atlassian **API token**, not your password. API tokens can
be revoked independently at
https://id.atlassian.com/manage-profile/security/api-tokens.

## Storage keys

All three keys live in the widget's own namespace (`jira-my-issues`). Readable
from any namespace via `services.storage.get(namespace: "jira-my-issues",
key: ...)`. Writable only through the widget's own storage surface
(`services.storage.set(key:value:)` from within the widget, or
`task42 storage set` from the CLI).

| Full address | Type | Description |
|---|---|---|
| `jira-my-issues/base` | string | Atlassian site base URL, e.g. `https://myorg.atlassian.net` (no trailing slash). |
| `jira-my-issues/email` | string | Email of the Atlassian account whose issues to list. |
| `jira-my-issues/token` | string | Atlassian API token (not a password). |

## Setting credentials via the CLI

Values must be valid JSON strings (double-quoted). The shell outer quoting
wraps the JSON string, so use single quotes to avoid escaping:

```bash
# Set the Atlassian site base URL
task42 storage set <task-id> jira-my-issues/base '"https://myorg.atlassian.net"'

# Set the account email
task42 storage set <task-id> jira-my-issues/email '"you@example.com"'

# Set the API token (generate at https://id.atlassian.com/manage-profile/security/api-tokens)
task42 storage set <task-id> jira-my-issues/token '"ATATT3xFfGF0..."'
```

After setting all three keys the widget will fetch and display assigned issues
on its next activation (open the widget or re-open the tab).

## Reading stored values

```bash
# Read the stored base URL
task42 storage get <task-id> jira-my-issues/base

# List all keys in the widget's namespace
task42 storage list <task-id> jira-my-issues
```

## Clearing credentials

```bash
task42 storage delete <task-id> jira-my-issues/base
task42 storage delete <task-id> jira-my-issues/email
task42 storage delete <task-id> jira-my-issues/token
```

Clearing any credential returns the widget to the setup form on next open.

## Widget lifecycle

1. **Setup state** — shown when any credential is missing. Presents a form
   collecting the base URL, email, and API token. On submit, credentials are
   saved to the widget's namespace and issues are fetched immediately.

2. **Loading state** — shown while the Jira REST API request is in flight.
   The widget runs:
   ```
   curl -s --max-time 15 -u <email>:<token>
     "<base>/rest/api/3/search?jql=assignee=currentUser()+AND+statusCategory!=Done&fields=summary,status&maxResults=50"
   ```
   via `services.shell` (never blocking the render path).

3. **Loaded state** — one row per issue. Each row shows:
   - Issue key (e.g. `PROJ-123`, monospaced, accent-colored)
   - Summary text (up to two lines)
   - Status chip (e.g. "In Progress")
   - "Start work session" button

   An empty result list is shown with a clear "No assigned issues" message,
   never a silent blank tile.

4. **Error state** — shown on any failure (non-parseable response, curl
   non-zero exit, storage unavailable). Names the problem and the remedy.
   Provides a "Retry" button and a "Reconfigure" button to update credentials.

## "Start work session" button

Each row's button computes `<base>/browse/<KEY>` and calls:

```
services.intents.execute(id: "global.new.task.jira", params: ["url": .string(issueURL)])
```

The `global.new.task.jira` intent (AC17/AC18) creates a task session seeded
with `jira/url = <issueURL>` and opens it. If the session already exists it
is re-focused. The existing "New Task" sheet intent is unaffected.

## No background polling

The widget fetches once on activation and on manual "Refresh". There is no
background watch loop in v1. Use the Refresh button in the toolbar to
re-fetch.

## Jira query

The widget always fetches with:

```
jql=assignee=currentUser()+AND+statusCategory!=Done&fields=summary,status&maxResults=50
```

The `currentUser()` function resolves to the account identified by the stored
email + API token credentials. Up to 50 issues are returned; pagination is
not implemented in v1.
