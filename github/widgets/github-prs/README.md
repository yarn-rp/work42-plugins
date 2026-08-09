# github-prs widget

Widget id: `github-prs`

Lists the current user's open GitHub pull requests (via `gh pr list --author
@me`) and renders one row per PR. Each row has a "Start code review session"
button that fires the `global.review.pr` palette intent with the PR URL,
opening (or re-focusing) that PR's code-review session in one click.

Storage namespace: `github` (reads `github/prs` for real-time status if
available).

## Status

Source (`Sources/Widget.swift`) is implemented in subtask
`feat/plugings-implementation.10`. The bundle scaffold (this directory) is
established by subtask `feat/plugings-implementation.8`.
