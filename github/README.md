# github — pre-built GitHub PR widget

Renders one browser tab per PR attached to the current session (task or
patrol), backed by the `github` storage namespace, and runs a background
watch loop that surfaces new PR activity as session events.

## Layout

```
github/
  Sources/
    Widget.swift    — Work42Widget implementation + @_cdecl entry points
  SKILL.md          — agent-facing skill: the storage convention + CLI usage
```

`widget.yaml` and the built `.dylib` are generated at install time — never
hand-edit or commit them.

## What it does

- Reads/writes `github/prs` (JSON array of `{url, status, merged_at}`) via
  `services.storage` — the same convention `task42 storage` and
  `patrol42 storage` expose to agents.
- One `BrowserSurface` tab per PR, chrome-as-header, persistent `"github"`
  login cookie jar shared with the built-in Browser widget.
- Lets the user select text on a PR page and attach it to the chat composer
  as a cited comment, resolving the exact file + line range from the PR's
  diff when possible.
- Polls `gh` in the background (via `services.shell`) for reviews, comments,
  CI checks, and merge/close/reopen, delivering each new occurrence as a
  fingerprinted session event (`task42 event` / `patrol42 event`) so nothing
  repeats on every poll.

See `SKILL.md` for the exact storage keys and CLI commands an agent uses to
drive this widget without it being open.

## Building

See the repo root [README](../README.md) for the build/install workflow.
