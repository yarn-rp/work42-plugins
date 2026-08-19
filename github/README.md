# github — Work42 GitHub plugin

Provides two GitHub widgets for Work42 sessions: the `github` PR browser (one
tab per attached PR, background watch loop) and the `github-prs` open-PRs list
(all your open PRs with one-click code-review session launch).

## Bundle layout

```
github/
  plugin.yaml                   plugin metadata (name, version, sdk_version)
  widgets/
    github/                     the github PR browser widget
      Sources/Widget.swift      Work42Widget implementation + @_cdecl entry points
      SKILL.md                  agent-facing skill: storage convention + CLI usage
    github-prs/                 the Home GitHub PR browser widget
      README.md                 usage and launch-contract reference
  skills/
    using-github/
      SKILL.md                  plugin-level skill: how both widgets work together
  tab-templates/
    github-review.json          UserTabTemplate: "GitHub Review" (UUID 1a2b3c4d-…)
```

`widget.yaml` and built `.dylib` files are generated at install time — never
hand-edit or commit them.

## What the widgets do

### widget:github

- Reads/writes `github/prs` (JSON array of `{url, status, merged_at}`) via
  `services.storage`.
- One `BrowserSurface` tab per attached PR; supports attach/detach in-widget.
- Background poll loop (60 s) delivers PR activity as fingerprinted
  `[system event]`s via `task42 event` / `patrol42 event`.
- Text-selection bubble for attaching quoted PR content to the chat composer,
  with diff-anchor resolution via `gh pr diff`.

### widget:github-prs

- Opens one PR-list browser tab per GitHub repository in the workspace.
- A GitHub-branded “Review GitHub PR” action for the currently viewed PR.
- The action resolves GitHub's stable pull-request head ref and fires `session.open.codeReview`
  with structured branch and initial widget-storage arguments, titling the
  session "Code Review: <PR title>" (fail-soft to "Code Review: PR #<number>").
- Session creation failures stay visible in Work42's blocking error dialog.

## Installing

```bash
work42 plugin install /path/to/work42-plugins/github
```

Or install from the git URL:

```bash
work42 plugin install https://github.com/yarn-rp/work42-plugins/github
```

The `github` plugin is also bundled inside the Work42 app and auto-installed
on first launch — manual install is only needed for modified copies or
development builds.

## See also

- `skills/using-github/SKILL.md` — full plugin skill (storage, events, intents)
- `widgets/github/SKILL.md` — widget-level skill (storage keys, CLI commands)
- Work42 repo `docs/plugins.md` — plugin format reference and authoring guide
