# figma — Work42 plugin

Figma integration for Work42: a **file browser widget** plus a declared **Figma
remote MCP**, wired through the work42 skill + MCP registry.

## What's inside

- **`widgets/figma`** — a session-scoped browser widget rendering one tab per
  attached Figma file. Empty state is a paste-URL form; the tab bar's `+`
  attaches another file, a tab's `×` detaches. Shares the `"browser"` cookie jar,
  so one Figma sign-in persists across all browser-based widgets. Stores the
  attached files as a JSON array at storage `figma/links` (`{url, name}`).
- **Figma remote MCP** (declared in `plugin.yaml`) — `https://mcp.figma.com/mcp`,
  bridged to stdio via `npx mcp-remote`. The work42 registry injects it into
  **task** and **code-review** sessions where the `figma` widget is active, and
  pre-approves `mcp__figma__*`. The first call triggers `mcp-remote`'s browser
  OAuth (no widget/token auth here).
- **`skills/using-figma`** — how the agent reads `figma/links` and queries the
  Figma MCP for design data.
- **`tab-templates/figma-work.json`** — a "Figma Work" tab opening `widget:figma`.

## Install

```bash
work42 plugin install <path-to>/work42-plugins/figma
```

`widget.yaml` and the widget `.dylib` are generated at install time — do not
commit them.
