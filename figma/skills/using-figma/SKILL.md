---
name: using-figma
description: |
  How to use the Work42 Figma plugin: the figma file browser widget
  (session-scoped, figma/links storage) plus the declared Figma remote MCP
  (mcp__figma__*, injected into task and code-review sessions). Covers reading
  the attached file links from the session's figma/links storage namespace,
  querying the Figma MCP for design data, and the mcp-remote browser OAuth on
  first call. Install with: work42 plugin install <path-to-figma-plugin>
---

# Using the Figma plugin

The Figma plugin gives an agent working in a task or code-review session direct
access to the Figma files the user has attached — both visually (the widget) and
programmatically (the Figma MCP).

## The widget: attached files live in storage

The `figma` widget (`widget:figma`) renders each attached Figma file as a tab in
a shared browser surface. It reads and writes ONE storage key:

| Namespace | Key     | Value                                              |
|-----------|---------|----------------------------------------------------|
| `figma`   | `links` | JSON array of `{ "url": <string>, "name": <string?> }` |

Read the attached files from a task session without opening the widget:

```bash
task42 storage get <task-id> figma/links
# -> [{"url":"https://www.figma.com/design/AbC123/My-Design","name":"My Design"}]
```

You can also attach a file programmatically (the widget picks it up live):

```bash
task42 storage set <task-id> figma/links '[{"url":"https://www.figma.com/design/AbC123/My-Design"}]'
```

The browser surface shares the `"browser"` cookie jar (`dataStoreKey: "browser"`)
with the built-in Browser and the Jira/GitHub widgets — the user signs in to
Figma once and the login persists across all browser-based widgets and restarts.

## The Figma MCP: query design data

When this plugin is installed and the `figma` widget is active in a **task** or
**code-review** session, the work42 registry injects the **Figma remote MCP**
(`https://mcp.figma.com/mcp`, bridged via `npx mcp-remote`) and pre-approves its
`mcp__figma__*` tools. Use those tools to read design data for the attached
files:

1. Read `figma/links` to get the file URL(s) the user attached.
2. Call the Figma MCP tools (`mcp__figma__*`) with those file references to fetch
   frames, components, variables, and other design data.

**First-call OAuth.** The very first Figma MCP call in a session opens a browser
authorize flow (handled entirely by `mcp-remote`, agent-side). Once the user
authorizes, the token is cached and subsequent calls return data. There is NO
Figma auth UI in the widget and NO token stored by work42 — auth is entirely
`mcp-remote`'s OAuth.

## Typical flow

1. User attaches a Figma file (paste-URL empty state, or the `+` in the tab bar).
2. Agent reads `figma/links` to learn which files are in scope.
3. Agent calls `mcp__figma__*` tools to inspect the design and implement against
   it (e.g. extract a component's specs, then build the matching UI).

## Scope

This skill and MCP cover the user's ATTACHED Figma files only. The registry
manages work42-defined skills + MCPs; nothing here touches the agent's own
external (non-work42) MCP configuration.
