---
name: using-figma
description: |
  How to use the Work42 Figma plugin: the figma file browser widget
  (session-scoped, figma/links storage). work42 injects NO Figma MCP — for
  design data the agent uses its OWN Figma connector (mcp__figma__*), which the
  user enables in their agent's connector settings (Claude is an approved Figma
  MCP Catalog client). Covers reading the attached file links from figma/links,
  and asking the user to enable a Figma connector when design tools aren't
  present. Install with: work42 plugin install <path-to-figma-plugin>
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

## Reading design data: use the agent's own Figma connector

**work42 does NOT inject a Figma MCP.** To read design data (frames, components,
variables, measurements) beyond what's visible in the widget, you use YOUR OWN
Figma connector — the same MCP mechanism your host agent already supports.

Why this way: Figma's MCP server is restricted to clients on Figma's approved
**MCP Catalog** (an allowlist). A host agent like **Claude** is an approved
client, so it can connect Figma directly with a normal one-time browser sign-in
— whereas a work42-bridged client is rejected. So the connector belongs to the
agent, not to work42.

### If you already have Figma tools

If `mcp__figma__*` tools are available in this session, just use them:

1. Read `figma/links` to get the file URL(s) the user attached (see below).
2. Call the Figma tools with those file references to fetch frames, components,
   variables, and other design data.

### If you do NOT have Figma tools

**Ask the user to enable the Figma connector in their agent, then retry.** For
Claude, that's the Figma connector in their client's **Connectors/MCP settings**
(e.g. add the Figma MCP server and complete the browser sign-in). Once enabled,
`mcp__figma__*` tools appear in future sessions and this section's first path
applies. Do not attempt to configure it yourself — it is the user's account +
their agent's connector settings.

Until a Figma connector is enabled, you can still see whatever is rendered
visually in the widget's browser tab, just not query structured design data.

## Typical flow

1. User attaches a Figma file (paste-URL empty state, or the `+` in the tab bar).
2. Agent reads `figma/links` to learn which files are in scope.
3. If Figma tools are available, inspect the design and implement against it;
   otherwise ask the user to enable their Figma connector first.

## Scope

This skill covers the user's ATTACHED Figma files (the `figma/links` storage) and
how to reach a Figma connector. work42 itself injects no Figma MCP — design-data
access is the agent's own connector.
