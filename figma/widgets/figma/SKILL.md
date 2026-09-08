---
name: widget-figma
description: |
  How to use the Figma widget (session tab kindId widget:figma).
  This widget shows the Figma file(s) attached to the current session (task or
  code review), one tab per file. It reads and writes the session's storage
  namespace: figma/links (JSON array of {url, name}). Use
  `task42 storage set <id> figma/links '[{"url":"<url>"}]'` on a task to attach
  a file without the widget open. When installed, the plugin also injects the
  agent's own Figma connector (mcp__figma__*) for reading design data — see using-figma.
---

# Figma widget

Renders the Figma file(s) attached to the current session inside Work42, one tab
per file. Sign in once anywhere in a browser-based widget (Browser, Jira,
GitHub, or here) and the login persists across all of them and across restarts —
they share one cookie jar (`dataStoreKey: "browser"`).

## Storage convention

- Namespace `figma`, key `links`: a JSON array of `{ "url": <string>, "name":
  <string?> }`. This is the source of truth for which files are attached; the
  `using-figma` skill and the Figma MCP read it.

Attach a file without opening the widget:

```bash
task42 storage set <task-id> figma/links '[{"url":"https://www.figma.com/design/AbC123/My-Design"}]'
```

The tab bar's `+` opens an attach sheet; a tab's `×` detaches that file.

## Design data

Reading design data (frames, components, variables) is done through the **Figma
MCP** (`mcp__figma__*`) — but work42 does NOT inject it. The agent uses its OWN
Figma connector, which the user enables in their agent's connector settings
(Claude is an approved Figma MCP Catalog client). If those tools aren't present,
ask the user to enable a Figma connector. See the `using-figma` skill.
