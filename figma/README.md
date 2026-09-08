# figma — Work42 plugin

Figma integration for Work42: a **file browser widget** plus a declared **Figma
Dev Mode MCP**, wired through the work42 skill + MCP registry.

## What's inside

- **`widgets/figma`** — a session-scoped browser widget rendering one tab per
  attached Figma file. Empty state is a paste-URL form; the tab bar's `+`
  attaches another file, a tab's `×` detaches. Shares the `"browser"` cookie jar,
  so one Figma sign-in persists across all browser-based widgets. Stores the
  attached files as a JSON array at storage `figma/links` (`{url, name}`).
- **Figma Dev Mode MCP** (declared in `plugin.yaml`) — `http://127.0.0.1:3845/mcp`,
  bridged to stdio via `npx mcp-remote`. The work42 registry injects it into
  **task** and **code-review** sessions where the `figma` widget is active, and
  pre-approves `mcp__figma__*`. Runs inside the Figma desktop app (enable it in
  Figma → Preferences → "Enable Dev Mode MCP Server"; needs a Dev/Full seat) —
  no OAuth, no token, no widget auth. The remote `https://mcp.figma.com/mcp`
  server is not used: it only accepts clients on Figma's approved MCP Catalog
  (allowlist).
- **`skills/using-figma`** — how the agent reads `figma/links` and queries the
  Figma MCP for design data.
- **`tab-templates/figma-work.json`** — a "Figma Work" tab opening `widget:figma`.

## Install

```bash
work42 plugin install <path-to>/work42-plugins/figma
```

`widget.yaml` and the widget `.dylib` are generated at install time — do not
commit them.
