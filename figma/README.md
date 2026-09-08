# figma — Work42 plugin

Figma integration for Work42: a **file browser widget** plus a **using-figma
skill**, wired through the work42 skill registry. work42 injects **no** Figma
MCP — design-data access is the host agent's own Figma connector.

## What's inside

- **`widgets/figma`** — a session-scoped browser widget rendering one tab per
  attached Figma file. Empty state is a paste-URL form; the tab bar's `+`
  attaches another file, a tab's `×` detaches. Shares the `"browser"` cookie jar,
  so one Figma sign-in persists across all browser-based widgets. Stores the
  attached files as a JSON array at storage `figma/links` (`{url, name}`).
- **No work42-injected Figma MCP.** Figma's MCP server is restricted to clients
  on Figma's approved **MCP Catalog** (an allowlist), so a work42-bridged client
  is rejected (`https://mcp.figma.com/mcp` → 403 on dynamic client registration).
  Instead, design-data access uses the **host agent's own Figma connector** — a
  client like **Claude** is catalog-approved and connects Figma directly with a
  one-time browser sign-in. The `using-figma` skill tells the agent to use its
  `mcp__figma__*` tools if present, and otherwise to ask the user to enable a
  Figma connector in their agent settings.
- **`skills/using-figma`** — how the agent reads `figma/links` and reaches design
  data through its own Figma connector.
- **`tab-templates/figma-work.json`** — a "Figma Work" tab opening `widget:figma`.

## Install

```bash
work42 plugin install <path-to>/work42-plugins/figma
```

`widget.yaml` and the widget `.dylib` are generated at install time — do not
commit them.
