# work42-plugins

Installable [Work42](https://github.com/yarn-rp/work42) plugin bundles — the
first-party plugins that ship with the app (Jira, GitHub) and any community
plugins built the same way.

A Work42 plugin is a **source folder** (or git repo) containing a `plugin.yaml`
manifest plus any combination of widgets, skills, and tab templates. Install
the entire bundle in one command:

```bash
work42 plugin install /path/to/plugin-folder
# or from a git URL:
work42 plugin install https://github.com/yarn-rp/work42-plugins/github
```

## Plugin bundle format

A valid plugin folder has the following layout (all subdirectories are
optional and discovered by convention — no per-item lists in the manifest):

```
<plugin-name>/
  plugin.yaml              required: name, version, description, author, sdk_version
  widgets/
    <slug>/
      Sources/
        Widget.swift       Work42Widget implementation + @_cdecl entry points
      SKILL.md             agent-facing widget skill (storage keys, CLI verbs)
      # widget.yaml and .dylib are generated at install time — do not commit them
  skills/
    <name>/
      SKILL.md             plugin-level skill (how to use the plugin's widgets together)
  tab-templates/
    <name>.json            UserTabTemplate JSON (must have a stable hardcoded UUID id)
```

### plugin.yaml fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Slug (alphanumeric + hyphens). Must be unique across installed plugins. |
| `version` | yes | Integer (e.g. `1`). Parsed as `Int` by the Work42 CLI — do not use semver strings. |
| `description` | yes | Human-readable description of the plugin. |
| `author` | yes | Author name or organization. |
| `sdk_version` | yes | Widget SDK ABI version. Must match the installed Work42 ABI. |

Example `plugin.yaml`:
```yaml
name: github
version: 1
description: GitHub PR browser and open-PRs list widgets for Work42.
author: work42
sdk_version: 4
```

### Tab template JSON shape

Tab templates must be valid `UserTabTemplate` JSON matching the Codable shape
used by `Work42TabTemplateStore`:

```json
{
  "id":             "<stable-UUID>",
  "name":           "My Template",
  "openItems":      ["widget:slug-a", "widget:slug-b"],
  "pinnedItems":    [],
  "isPlanView":     false,
  "openFileWidgets": [],
  "browserTabs":    []
}
```

`id` must be a fixed, hardcoded UUID (never randomly generated at install time)
so reinstalling the plugin is idempotent and does not create duplicate templates
in the ⌘⇧T picker.

`openItems` and `pinnedItems` use the `widget:<slug>` kindId format — the same
strings used in session tab state.

## What's here

```
work42-plugins/
  github/              GitHub plugin bundle
    plugin.yaml
    widgets/
      github/          GitHub PR browser widget
      github-prs/      Open-PRs list widget (scaffold; Widget.swift in subtask .10)
    skills/
      using-github/    Plugin-level skill: using both GitHub widgets together
    tab-templates/
      github-review.json   "GitHub Review" template (UUID 1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d)
  jira/                Jira plugin bundle
    plugin.yaml
    widgets/
      jira/            Jira issue browser widget
      jira-my-issues/  Assigned-issues list widget (scaffold; Widget.swift in subtask .11)
    skills/
      using-jira/      Plugin-level skill: using both Jira widgets together
    tab-templates/
      jira-work.json       "Jira Work" template (UUID 2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e)
```

## Installing a plugin

### From a local path

```bash
work42 plugin install /path/to/work42-plugins/github
work42 plugin install /path/to/work42-plugins/jira
```

### From a git URL

```bash
work42 plugin install https://github.com/yarn-rp/work42-plugins/github
```

The installer:
1. Copies (or clones) the plugin folder into `~/.work42/plugins/<name>/`.
2. Materializes each widget into `~/.work42/widgets/<slug>/` (copy prebuilt dylib
   if present and ABI-matching, otherwise `work42 widget build <slug>`).
3. Symlinks widget skills into `~/.claude/skills/widget-<slug>/`.
4. Symlinks plugin skills into `~/.claude/skills/<plugin>-<name>/`.
5. Writes `plugin.lock.json` recording the resolved slugs.
6. Tab templates are registered on the next app launch (or immediately if the
   app is running and watching `~/.work42/plugins/`).

### Managing plugins

```bash
# List installed plugins
work42 plugin list

# List with JSON output (name, version, widgets, skills, tab templates)
work42 plugin list --json

# Remove a plugin (preserves storage data)
work42 plugin remove github
```

## Bundled plugins (auto-install on launch)

The `jira` and `github` plugins ship pre-compiled inside the Work42 app bundle.
On first launch, `PrebuiltPluginMaterializer` runs `work42 plugin install` for
each bundled plugin (copy-only — no compile) and records a per-plugin opt-out
flag if you want to skip one.

If `~/.work42/widgets/github/` or `~/.work42/widgets/jira/` already exist from
a previous install, the materializer adopts them in-place (records them in the
plugin lock) rather than creating a namespaced duplicate.

## Slug collision and auto-namespacing

If a plugin widget's slug is already claimed by another plugin, the installer
auto-namespaces the new widget to `<plugin>-<widget>` (suffixing `-2`, `-3`
until free), rewrites the widget's `id` string and every `widget:<originalSlug>`
reference in the plugin's bundled tab templates, and builds — without failing
the install. See `docs/plugins.md` in the main Work42 repo for details.

## Building a new plugin

1. Start with `work42 widget new <slug>` for each widget in the main Work42
   app to get the scaffolded `Sources/Widget.swift` + `SKILL.md` shape.
2. Develop against `Work42WidgetKit`.
3. Organize into a plugin folder with `plugin.yaml` + `widgets/` + `skills/`
   + `tab-templates/`.
4. Test locally: `work42 plugin install /path/to/your-plugin`.

See the main [work42](https://github.com/yarn-rp/work42) repo's
`docs/plugins.md` for the full authoring reference (SDK, bundle format,
auto-namespacing contract, tab-template authoring).

## Contributing

PRs welcome. A new plugin is a new top-level folder with `plugin.yaml` and the
standard bundle layout above. Follow the existing `github/` and `jira/` bundles
as examples.

## License

MIT — see [LICENSE](LICENSE).
