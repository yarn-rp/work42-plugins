# github-prs widget

Widget id: `github-prs`

Opens one GitHub pull-request browser tab per workspace repository. Its
GitHub-branded “Review GitHub PR” action resolves the currently viewed PR to
GitHub's stable `refs/pull/<number>/head` ref and fires `session.open.codeReview` with a typed repository branch
map plus initial `github/prs` session metadata, opening that Code Review
session in one click.

Storage namespace: `github` (reads `github/prs` for real-time status if
available).

## Status

Source (`Sources/Widget.swift`) is implemented in subtask
`feat/plugings-implementation.10`. The bundle scaffold (this directory) is
established by subtask `feat/plugings-implementation.8`.
