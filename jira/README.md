# jira — pre-built Jira widget

Shows the tracker issue linked to the current session (task or patrol),
backed by the `jira` storage namespace.

## Layout

```
jira/
  Sources/
    Widget.swift    — Work42Widget implementation + @_cdecl entry points
  SKILL.md          — agent-facing skill: the storage convention + CLI usage
```

`widget.yaml` and the built `.dylib` are generated at install time — never
hand-edit or commit them.

## What it does

- Empty state: a paste-URL form that writes `jira/url` + the parsed
  `jira/key` via `services.storage`.
- Assigned state: renders the issue in a `BrowserSurface`, sharing the
  `"browser"` login cookie jar with the built-in Browser widget — sign in
  once anywhere and every browser-based widget inherits the session.

See `SKILL.md` for the exact storage keys and CLI commands an agent uses to
attach a tracker link without the widget being installed.

## Building

See the repo root [README](../README.md) for the build/install workflow.
