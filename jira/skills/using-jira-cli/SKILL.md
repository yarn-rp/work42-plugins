---
name: using-jira-cli
description: |
  Operate Jira Cloud through Atlassian's official `acli` command-line tool.
  Use when an agent needs to inspect, search, label, transition, or comment on
  Jira work items, or when setting up and troubleshooting Jira CLI
  authentication. Resolves the work item the current Work42 session is about
  from the Jira widget's storage. Prefer this skill over the Atlassian Rovo MCP
  connector.
---

# Using Jira CLI

Use Atlassian's official `acli` for Jira agent operations. Keep the browser-based
Work42 widgets for visual browsing; use this skill for structured reads and
explicitly requested writes.

## Find the work item this session is about

Before running any `acli` command, resolve the concrete issue key from the
session's own context — do **not** ask the user for a key you can already read.
The Jira widget persists the linked issue(s) in the task's Work42 storage, which
the `task42` CLI reads. The task id is the session's git branch.

```bash
TASK="$(git rev-parse --abbrev-ref HEAD)"

# Modern: an array of {url, key} objects (one per attached issue).
task42 storage get "$TASK" jira/issues

# Legacy single-issue fallback, when jira/issues is absent:
task42 storage get "$TASK" jira/url
task42 storage get "$TASK" jira/key
```

Extract the key (e.g. with `jq -r '.[0].key'` on `jira/issues`) and use it as the
`PROJ-123` placeholder in every command below. The pinned board the *My Issues*
widget opens is stored separately:

```bash
task42 storage get "$TASK" jira-my-issues/board   # a board/filter URL
```

If these reads come back empty or error — the widget isn't attached, this isn't a
task session, or the board is configured only at project/Home scope (not visible
to `task42 storage`) — then, and only then, ask the user which issue or board to
operate on. Never guess a key.

## Install and authenticate

Install on macOS with Homebrew, then verify the binary:

```bash
brew tap atlassian/homebrew-acli
brew install acli
acli --version
```

Prefer browser authentication when available:

```bash
acli jira auth login --web
```

For API-token authentication, obtain a Jira API token and pass it through stdin
instead of placing it in the command arguments:

```bash
echo '<token>' | acli jira auth login \
  --site 'org.atlassian.net' \
  --email 'you@org.com' \
  --token
```

Never print, store in the repository, or repeat the token in a response. Check
the selected account before operating:

```bash
acli jira auth status
```

## Read before writing

Resolve the exact work-item key and inspect its current values before a mutation:

```bash
acli jira workitem view PROJ-123 --fields status,labels --json
```

Use `--json` for machine parsing. Treat a nonzero exit, empty response, or
unexpected JSON as a failed read; do not infer state.

Search with JQL when the key is unknown:

```bash
acli jira workitem search \
  --jql 'project = PROJ AND statusCategory != Done ORDER BY updated DESC' \
  --fields 'key,summary,status,labels' \
  --limit 50 \
  --json
```

Use `--paginate` only when the complete result set is required. Quote JQL so the
shell does not interpret it.

## Edit labels

Only mutate Jira when the user explicitly asks. Re-read the item, target keys
directly where possible, and verify afterward:

```bash
acli jira workitem edit --key 'PROJ-123' --labels 'backend,urgent' --yes --json
acli jira workitem edit --key 'PROJ-123' --remove-labels 'urgent' --yes --json
acli jira workitem view PROJ-123 --fields status,labels --json
```

Do not use `--jql` for a bulk edit unless the user explicitly authorized the
entire matching set. Run the equivalent search first and report the targets.

## Transition status

Transition one or more known keys to a named Jira status:

```bash
acli jira workitem transition --key 'PROJ-123' --status 'In Progress' --yes --json
```

Status names are workflow-specific. If the command rejects a status, report the
error rather than guessing another transition.

## Add a comment

Add a plain-text comment to a known item:

```bash
acli jira workitem comment create \
  --key 'PROJ-123' \
  --body 'Implementation is ready for review.' \
  --json
```

For longer content, use `--body-file <path>` so quoting and newlines are
preserved. Show the intended comment to the user before posting unless they
already supplied the exact text.

## Failure handling

- If `acli` is missing, provide the install commands; do not fall back silently.
- If authentication fails, run `acli jira auth status` and ask the user to log
  in; never request that a token be pasted into chat.
- If Jira rejects a write, preserve the original state, report stderr concisely,
  and stop.
- Do not fall back to the Atlassian Rovo MCP connector unless the user explicitly
  requests it.
