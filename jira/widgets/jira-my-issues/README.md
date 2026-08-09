# jira-my-issues widget

Widget id: `jira-my-issues`

Lists the current user's assigned Jira issues (via the Jira REST search API
with `jql=assignee=currentUser()`) and renders one row per issue. Each row
has a "Start work session" button that fires the `global.new.task` palette
intent with the issue URL, opening a task session seeded with that issue's
`jira/url`.

Requires `jira/base` (your Atlassian domain, e.g. `myorg.atlassian.net`),
`jira/email`, and `jira/token` (an Atlassian API token) to be stored in the
`jira` storage namespace. The widget provides an empty-state setup form when
any of these are absent.

## Status

Source (`Sources/Widget.swift`) is implemented in subtask
`feat/plugings-implementation.11`. The bundle scaffold (this directory) is
established by subtask `feat/plugings-implementation.8`.
