---
name: using-figma
description: |
  How to use the Work42 Figma plugin: the figma file browser widget
  (session-scoped, figma/links storage) plus the declared Figma Dev Mode MCP
  (mcp__figma__*, injected into task and code-review sessions). Covers reading
  the attached file links from the session's figma/links storage namespace,
  querying the Figma MCP for design data, and the local Dev Mode MCP server
  requirement (Figma desktop app + Dev/Full seat). Install with:
  work42 plugin install <path-to-figma-plugin>
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
**code-review** session, the work42 registry injects the **Figma Dev Mode MCP**
(`http://127.0.0.1:3845/mcp`, bridged via `npx mcp-remote`) and pre-approves its
`mcp__figma__*` tools. Use those tools to read design data for the attached
files:

1. Read `figma/links` to get the file URL(s) the user attached.
2. Call the Figma MCP tools (`mcp__figma__*`) with those file references to fetch
   frames, components, variables, and other design data.

**Requires the Figma desktop app.** The Dev Mode MCP server runs locally inside
the Figma desktop app — the user must have it open and enable it once via
**Figma → Preferences → "Enable Dev Mode MCP Server"** (needs a Dev or Full
seat). It uses the desktop app's own login, so there is NO OAuth, no token, and
no widget auth. If the `mcp__figma__*` tools return a connection error, the most
likely cause is the Figma desktop app not being open / Dev Mode MCP not enabled.

The remote server (`https://mcp.figma.com/mcp`) is NOT used because it only
accepts clients on Figma's approved MCP Catalog (allowlist).

## Typical flow

1. User attaches a Figma file (paste-URL empty state, or the `+` in the tab bar).
2. Agent reads `figma/links` to learn which files are in scope.
3. Agent calls `mcp__figma__*` tools to inspect the design and implement against
   it (e.g. extract a component's specs, then build the matching UI).

## Scope

This skill and MCP cover the user's ATTACHED Figma files only. The registry
manages work42-defined skills + MCPs; nothing here touches the agent's own
external (non-work42) MCP configuration.
