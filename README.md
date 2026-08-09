# work42-plugins

Pre-built [Work42](https://github.com/yarn-rp/work42) custom widgets — the
first-party plugins that ship with the app (Jira, GitHub PR) and any
community widgets built the same way.

Work42 sessions (tasks and patrol code-reviews) are backed by a generic
per-session key-value store (`task42 storage` / `patrol42 storage`) and a
widget SDK (`Work42WidgetKit`) that lets any widget render UI, run shell
commands, and read/write its own storage namespace. Nothing vendor-specific
lives in the Work42 core — Jira and GitHub support are entirely implemented
as widgets in this repo.

## What's here

```
work42-plugins/
  github/           the GitHub PR widget
    Sources/Widget.swift
    SKILL.md        agent-facing usage doc (storage convention, CLI verbs)
    README.md
  jira/             the Jira widget
    Sources/Widget.swift
    SKILL.md
    README.md
```

Each widget folder is self-contained: one `Work42Widget` implementation in
`Sources/Widget.swift`, plus a `SKILL.md` that teaches an agent how to drive
the widget's storage convention from the CLI without the widget needing to
be open.

## Installing a widget

Widgets are ordinary custom widgets from Work42's point of view — the app's
`CustomWidgetLoader` loads anything it finds under `~/.work42/widgets/<slug>/`.
To install one from this repo:

```bash
# Clone this repo somewhere
git clone https://github.com/yarn-rp/work42-plugins.git

# Copy (or symlink) the widget you want into place
cp -R work42-plugins/github ~/.work42/widgets/github

# Build it against your installed Work42 app's shipped SDK
WORK42_APP_PATH="/Applications/Work42.app" work42 widget build github
work42 widget reload github
```

`jira` and `github` also ship **bundled inside the Work42 app itself** and
are installed by default on first launch (see
[`PrebuiltWidgetMaterializer`](https://github.com/yarn-rp/work42/blob/main/app/Sources/Work42App/Widgets/PrebuiltWidgetMaterializer.swift)
in the main repo) — you only need the manual steps above for widgets that
aren't bundled, or to build a modified copy of a bundled one.

## Building a new widget

Start from `work42 widget new <slug>` in the main Work42 app (see the
`work42-custom-widgets` skill in the main repo), develop it against
`Work42WidgetKit`, then move the finished folder here to share it.

## Contributing

PRs welcome — a new widget is just a new top-level folder with the same
shape as `github/` or `jira/`: `Sources/Widget.swift` + `SKILL.md` +
`README.md`. See the main [work42](https://github.com/yarn-rp/work42) repo's
`docs/custom-widgets.md` for the full SDK reference (`services.storage`,
`services.shell`, `services.composer`, `BrowserSurface`).

## License

MIT — see [LICENSE](LICENSE).
