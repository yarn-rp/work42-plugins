# jira — Work42 Jira plugin

Provides two Jira widgets for Work42 sessions: the `jira` issue browser (renders
the issue linked to the current session) and the `jira-my-issues` assigned-issues
list (all your assigned issues with one-click work session launch).

## Bundle layout

```
jira/
  plugin.yaml                   plugin metadata (name, version, sdk_version)
  widgets/
    jira/                       the jira issue browser widget
      Sources/Widget.swift      Work42Widget implementation + @_cdecl entry points
      SKILL.md                  agent-facing skill: storage convention + CLI usage
    jira-my-issues/             the jira-my-issues list widget (subtask .11)
      README.md                 scaffold stub — Widget.swift added by subtask .11
  skills/
    using-jira/
      SKILL.md                  plugin-level skill: how both widgets work together
  tab-templates/
    jira-work.json              UserTabTemplate: "Jira Work" (UUID 2b3c4d5e-…)
```

`widget.yaml` and built `.dylib` files are generated at install time — never
hand-edit or commit them.

## What the widgets do

### widget:jira

- Reads/writes `jira/url` and `jira/key` via `services.storage` (own namespace
  `"jira"`, since widget id == storage namespace).
- Empty state: a paste-URL form that writes `jira/url` + the parsed `jira/key`.
- Assigned state: full-page `BrowserSurface` for the issue, sharing the
  `"browser"` cookie jar with the built-in Browser widget — sign in once.
- Declares Atlassian Cloud URLs to Work42's `Open Link` intent. A clicked link
  navigates the in-memory browser only and does not write `jira/url` or
  `jira/key`; URL routes, queries, and fragments are preserved.
- "Change ticket" button returns to the paste-URL form.

### widget:jira-my-issues

- Explicitly declares no link-opening handlers; it remains a Home dashboard,
  not an `Open Link` destination.
- Fetches issues assigned to the current user via the Jira REST API
  (`jql=assignee=currentUser()`) using credentials from the `jira` storage
  namespace (`jira/base`, `jira/email`, `jira/token`).
- One row per issue with a "Start work session" button.
- The button fires `services.intents.execute(id: "global.new.task", params:
  ["jiraURL": issueURL])`, creating a task session seeded with that issue's
  `jira/url` in one click.
- Setup form when credentials are absent; named error state on API failure.

## Installing

```bash
work42 plugin install /path/to/work42-plugins/jira
```

Or install from the git URL:

```bash
work42 plugin install https://github.com/yarn-rp/work42-plugins/jira
```

The `jira` plugin is also bundled inside the Work42 app and auto-installed on
first launch — manual install is only needed for modified copies or development
builds.

## See also

- `skills/using-jira/SKILL.md` — full plugin skill (storage, credentials, intents)
- `widgets/jira/SKILL.md` — widget-level skill (storage keys, CLI commands)
- Work42 repo `docs/plugins.md` — plugin format reference and authoring guide
