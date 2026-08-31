---
name: using-jira-cli
description: |
  Operate Jira Cloud through Atlassian's official `acli` command-line tool.
  Use when an agent needs to inspect, search, label, transition, or comment on
  Jira work items, or when setting up and troubleshooting Jira CLI
  authentication. Prefer this skill over the Atlassian Rovo MCP connector.
---

# Using Jira CLI

Use Atlassian's official `acli` for Jira agent operations. This skill is
self-contained: it depends only on `acli` and a work-item key, so it works in any
context — a Work42 session, a plain shell, or an automation. Keep the
browser-based Work42 widgets for visual browsing; use this skill for structured
reads and explicitly requested writes.

## Determine the work item

Every command needs a work-item key like `PROJ-123`. Resolve it from whatever
context you already have, in this order — do not ask for a key you can derive:

1. **A Jira URL already in view** — from the user's message, an open Jira tab, or
   a link in the conversation. Issue keys appear in the path or query, e.g.
   `.../browse/PROJ-123`, `.../issues/PROJ-123`, or `?selectedIssue=PROJ-123`.
   Extract the `PROJ-123` token (uppercase project code, hyphen, number):

   ```bash
   echo "$JIRA_URL" | grep -oiE '[A-Z][A-Z0-9]+-[0-9]+' | head -1
   ```

2. **A key the user named directly** (`PROJ-123`, "the auth bug PROJ-482").

3. **Search when the key is unknown** — use JQL (see *Read before writing*) to
   find candidates, then confirm the target before acting.

Only ask the user which item to operate on when none of the above yields a key.
Never guess a key or a project code.

> Optional Work42 integration: if a caller wants this skill to auto-target the
> issue a Work42 widget is showing, it should pass that issue's URL or key in as
> context (e.g. in the prompt). The skill itself stays free of any Work42- or
> task42-specific lookup so it remains reusable elsewhere.

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
