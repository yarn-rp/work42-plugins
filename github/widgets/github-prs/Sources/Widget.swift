// Widget.swift — github-prs widget (feat/plugings-implementation.17)
//
// REWORK: Replaces the old gh-list approach entirely.
//
// DESIGN (settled with Yan):
//   A HOME-surface browser widget that renders ONE TAB PER WORKSPACE REPOSITORY
//   plus any manually stored repositories, at each repo's GitHub PRs page
//   (https://github.com/<owner>/<repo>/pulls).
//
// REPO ENUMERATION (shell, no gh CLI required):
//   On Home, services.shell cwd = the multi-repo workspace root. The widget:
//   1. Checks if the root itself is a git repo (.git present). If so, yields it.
//   2. Otherwise enumerates depth-1 subdirs that are git repos.
//   For each: `git -C <dir> config --get remote.origin.url` → parse owner/repo.
//
// TABS:
//   One BrowserSurface tab per workspace repo at its /pulls page. Uses
//   model.replaceTabs (via configure closure and BrowserSurface.model(forKey:)).
//
// ACTION-AREA INTENT:
//   "Review GitHub PR" — placement: [.palette, .actionArea].
//   isEnabled closure returns true ONLY when the active tab's URL (model.urlDraft)
//   matches a PR page (/pull/<N> path). Enabled = the button appears in the
//   action center, resolves the PR head branch with `gh`, and fires the typed
//   session.open.codeReview intent with branch + initial github/prs metadata.
//
// FAIL LOUD:
//   If no GitHub repos are found or the shell fails, renders a fail-loud error
//   card with a retry button — never a blank tile.
//
// SESSION METADATA: Seeds github/prs in the new session so the separate
// `github` session widget can render and monitor the selected pull request.
// Uses `git` for repository discovery and authenticated `gh` only when the
// user asks to open the currently viewed PR as a Code Review session.
//
// WIDGET ID: "github-prs" (unchanged — the loader keyed this slug).

import AppKit
import Foundation
import Observation
import SwiftUI
import Work42WidgetKit

// MARK: - RepoInfo

/// One workspace git repository resolved to its GitHub PRs page URL.
struct RepoInfo: Sendable, Equatable {
    /// RepoDiscovery-compatible workspace key ("." for a root repo). Nil for
    /// manually added repositories that have no local checkout.
    var repoKey: String?
    /// "owner/repo" — used as the browser tab title.
    var ownerRepo: String
    /// https://github.com/<owner>/<repo>/pulls
    var url: URL
    /// Stable UUID for the BrowserSurface tab (survives replaceTabs idempotently).
    var tabID: UUID
}

// MARK: - Load state

enum GitHubPRsLoadState: Sendable {
    case loading
    /// Non-empty repos → BrowserSurface; empty is handled by caller (treated as error).
    case ready([RepoInfo])
    case error(String)
}

// MARK: - GitHub remote URL parsing
//
// Mirrors Work42Core.GitRemote — inlined here because widget dylibs link only
// Work42UI + Work42WidgetKit. Any format changes there should be kept in sync.

/// Parse a git remote URL into (owner, repo). Returns nil for non-GitHub URLs.
///
/// Recognised forms:
///   git@github.com:owner/repo.git          SSH shorthand
///   https://github.com/owner/repo(.git)    HTTPS
///   ssh://git@github.com/owner/repo.git    SSH explicit
private func parseGitHubOwnerRepo(_ remoteURL: String) -> (owner: String, repo: String)? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()

    // SSH shorthand: git@github.com:owner/repo.git
    let sshShortPrefix = "git@github.com:"
    if lower.hasPrefix(sshShortPrefix) {
        return splitGitHubOwnerRepo(String(trimmed.dropFirst(sshShortPrefix.count)))
    }
    // HTTPS: https://github.com/owner/repo(.git)
    if lower.hasPrefix("https://github.com/") || lower.hasPrefix("http://github.com/") {
        // Find the slash after the host (skip "https://" = 8 chars)
        let startIdx = trimmed.index(trimmed.startIndex, offsetBy: min(8, trimmed.count))
        if let slashRange = trimmed.range(of: "/", range: startIdx..<trimmed.endIndex) {
            return splitGitHubOwnerRepo(String(trimmed[slashRange.upperBound...]))
        }
    }
    // SSH explicit: ssh://git@github.com/... or ssh://github.com/...
    for prefix in ["ssh://git@github.com/", "ssh://github.com/"] {
        if lower.hasPrefix(prefix) {
            return splitGitHubOwnerRepo(String(trimmed.dropFirst(prefix.count)))
        }
    }
    return nil
}

/// Split `"owner/repo(.git)(/)"` into lower-cased `(owner, repo)`. Returns nil
/// when the path doesn't have at least two non-empty components.
private func splitGitHubOwnerRepo(_ path: String) -> (owner: String, repo: String)? {
    var cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if cleaned.lowercased().hasSuffix(".git") {
        cleaned = String(cleaned.dropLast(4))
    }
    cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let parts = cleaned.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    let owner = String(parts[0]).lowercased()
    let repo  = String(parts[1]).lowercased()
    guard !owner.isEmpty, !repo.isEmpty else { return nil }
    return (owner, repo)
}

/// Parse user input for the add-repository form. Accepts a GitHub remote/URL or
/// exactly `owner/repo`; rejects URLs for any other host and extra path parts.
private func parseAddedGitHubRepo(_ input: String) -> (owner: String, repo: String)? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let parsed = parseGitHubOwnerRepo(trimmed) { return parsed }
    guard !trimmed.contains("://"), !trimmed.contains("@") else { return nil }
    let parts = trimmed
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    return splitGitHubOwnerRepo(trimmed)
}

/// Return true when `urlString` points to a GitHub PR page (path: /owner/repo/pull/<N>).
private func isGitHubPRPage(_ urlString: String) -> Bool {
    githubPRReference(urlString) != nil
}

private func githubPRReference(_ urlString: String) -> (ownerRepo: String, number: Int)? {
    guard !urlString.isEmpty,
          let url = URL(string: urlString),
          let host = url.host,
          host.lowercased().hasSuffix("github.com")
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    // Expected: ["owner", "repo", "pull", "N", ...]
    guard parts.count >= 4,
          parts[2].lowercased() == "pull",
          let number = Int(parts[3])
    else { return nil }
    return ("\(parts[0].lowercased())/\(parts[1].lowercased())", number)
}

// MARK: - PATH enrichment

/// Prepend common Homebrew / local dirs to PATH for git invocations.
private let enrichedPathPrefix = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

// MARK: - GitHubPRsWidget

/// Widget id: `github-prs`. Home-surface browser widget showing one tab per
/// workspace repo at its GitHub PRs page. Requires `git` in PATH.
///
/// Placement: Home surface only (enabledLayouts = [.home]) because the repo
/// enumeration relies on services.shell cwd being the workspace root, which is
/// guaranteed only on the Home surface.
@Observable
@MainActor
final class GitHubPRsWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "github-prs"
    let title = "GitHub PRs"
    let icon = "arrow.triangle.pull"
    var iconImageData: Data? { GitHubPRsReviewAgent.githubMarkPNG }

    /// Home-only: enumeration depends on workspace root being the shell's cwd.
    var enabledLayouts: Set<WidgetLayout> { [.home] }

    /// This dashboard starts review sessions but is not a link destination.
    let linkIntents: [WidgetLinkIntentSpec] = []

    // MARK: - Observed state (drives the view)

    var loadState: GitHubPRsLoadState = .loading
    var showingAddRepoForm = false

    // MARK: - Intents

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "start-code-review",
                title: "Review GitHub PR",
                icon: "arrow.triangle.pull",
                iconImageData: GitHubPRsReviewAgent.githubMarkPNG,
                brandColorHex: "#1F2328",
                keywords: ["review", "code review", "pr", "pull request", "session"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    let urlString = BrowserSurface.model(forKey: self.id)?.urlDraft ?? ""
                    guard let reference = githubPRReference(urlString),
                          case .ready(let repos) = self.loadState
                    else { return false }
                    return repos.contains {
                        $0.ownerRepo.lowercased() == reference.ownerRepo && $0.repoKey != nil
                    }
                },
                perform: { [weak self] in
                    guard let self else { return }
                    let urlString = BrowserSurface.model(forKey: self.id)?.urlDraft ?? ""
                    guard let reference = githubPRReference(urlString) else { return }
                    guard let svc = self.services else { return }
                    guard case .ready(let repos) = self.loadState,
                          let repo = repos.first(where: {
                              $0.ownerRepo.lowercased() == reference.ownerRepo
                          }),
                          let repoKey = repo.repoKey
                    else {
                        throw WidgetServiceError(
                            message: "This pull request does not have a local workspace checkout.",
                            suggestion: "Review sessions require an auto-discovered workspace repository."
                        )
                    }
                    // Review the PR by its HEAD BRANCH NAME so the local review
                    // branch tracks `origin/<branch>` — a normal git fetch keeps
                    // it fresh and Pull fast-forwards it (the row shows "behind"
                    // when the PR advances, never a bogus "merge conflicts").
                    // Fork PRs (whose head branch isn't on this origin) fall back
                    // to the stable `refs/pull/<N>/head` ref (checked out detached).
                    var reviewRef = "refs/pull/\(reference.number)/head"
                    var prTitle = "PR #\(reference.number)"
                    if let result = try? await svc.shell.run(command:
                        "\(ghReviewPathPrefix) && gh pr view \(reference.number) "
                        + "--repo \(reference.ownerRepo) --json title,headRefName,isCrossRepository"
                    ), result.exitCode == 0,
                       let data = result.stdout.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let title = (obj["title"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                            prTitle = title
                        }
                        let isFork = (obj["isCrossRepository"] as? Bool) ?? false
                        if !isFork, let head = (obj["headRefName"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty {
                            reviewRef = head
                        }
                    }
                    try await svc.intents.execute(
                        id: "session.open.codeReview",
                        params: [
                            "kind": .string("codeReview"),
                            "name": .string("PR Review: \(prTitle)"),
                            "codeReview": .object([
                                "branchesByRepository": .object([
                                    repoKey: .string(reviewRef),
                                ]),
                            ]),
                            "initialWidgetStorage": .object([
                                "github": .object([
                                    "prs": .array([
                                        .object([
                                            "url": .string(urlString),
                                            "status": .string("open"),
                                            "merged_at": .null,
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]
                    )
                }
            ),
        ]
    }

    // MARK: - Internal

    private var services: SessionServices?
    private var enumerationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        enumerationTask?.cancel()
        loadState = .loading
        enumerationTask = Task { @MainActor [weak self] in
            await self?.enumerateRepos()
        }
    }

    func deactivate() {
        enumerationTask?.cancel()
        enumerationTask = nil
        services = nil
        loadState = .loading
        showingAddRepoForm = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(GitHubPRsRootView(widget: self, services: services))
    }

    // MARK: - Repo enumeration

    /// Enumerate immediate git repos in the workspace root via services.shell,
    /// resolve each to a GitHub remote, and update `loadState`.
    ///
    /// Shell output: one line per resolved repo → "<path>|<remote_url>".
    /// Empty stdout → no GitHub repos found → error state.
    func enumerateRepos() async {
        guard let services else { return }
        let manualOwnerRepos = await loadManualOwnerRepos(services: services)

        // Shell script:
        //   If the workspace root is itself a git repo, use it (solo-repo workspace).
        //   Otherwise enumerate depth-1 subdirs that have a .git directory
        //   (multi-repo workspace; RepoDiscovery's depth-1 rule).
        //   For each repo get its origin remote URL and emit "<path>|<url>".
        let cmd = """
            \(enrichedPathPrefix)
            if [ -d ".git" ]; then
              _url=$(git config --get remote.origin.url 2>/dev/null)
              [ -n "$_url" ] && printf '.|%s\\n' "$_url"
            else
              for _d in */; do
                [ -d "${_d}.git" ] || continue
                _url=$(git -C "${_d%/}" config --get remote.origin.url 2>/dev/null)
                [ -n "$_url" ] && printf '%s|%s\\n' "${_d%/}" "$_url"
              done
            fi
            """

        let result: WidgetShellResult
        do {
            result = try await services.shell.run(command: cmd)
        } catch {
            if !manualOwnerRepos.isEmpty {
                publishRepos(merging: [], manualOwnerRepos: manualOwnerRepos)
                return
            }
            loadState = .error(
                "Could not enumerate workspace repositories.\n\n" +
                error.localizedDescription +
                "\n\nEnsure git is installed and in PATH."
            )
            return
        }

        guard result.exitCode == 0 else {
            if !manualOwnerRepos.isEmpty {
                publishRepos(merging: [], manualOwnerRepos: manualOwnerRepos)
                return
            }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty
                ? "Shell exited with code \(result.exitCode)."
                : String(stderr.prefix(300))
            loadState = .error("Repository enumeration failed.\n\n\(detail)")
            return
        }

        // Parse "path|remote_url" lines into RepoInfo values.
        var repos: [RepoInfo] = []
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let remoteURL = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (owner, repo) = parseGitHubOwnerRepo(remoteURL),
                  let prsURL = URL(string: "https://github.com/\(owner)/\(repo)/pulls")
            else { continue }
            repos.append(RepoInfo(
                repoKey: String(parts[0]),
                ownerRepo: "\(owner)/\(repo)",
                url: prsURL,
                tabID: UUID()
            ))
        }

        repos = merge(autoRepos: repos, manualOwnerRepos: manualOwnerRepos)

        if repos.isEmpty {
            let rawOutput = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg: String
            if rawOutput.isEmpty {
                msg = "No git repositories found in the workspace root, " +
                      "or none have a GitHub remote.\n\n" +
                      "Ensure each workspace repo has `remote.origin.url` " +
                      "pointing to a GitHub URL (HTTPS or SSH)."
            } else {
                msg = "Repos were found but none resolved to a GitHub remote.\n\n" +
                      "Ensure each workspace repo has `remote.origin.url` " +
                      "pointing to a GitHub URL."
            }
            loadState = .error(msg)
        } else {
            publishRepos(repos)
        }
    }

    /// Validate and persist one manual repository. Invalid input returns before
    /// touching storage, preserving the prior list exactly.
    func addManualRepo(_ input: String) async -> String? {
        guard let services else { return "The widget is not active." }
        guard let (owner, repo) = parseAddedGitHubRepo(input) else {
            return "Enter owner/repo or a github.com repository URL."
        }

        let normalized = "\(owner)/\(repo)"
        var stored = await loadManualOwnerRepos(services: services)
        if !stored.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            stored.append(normalized)
            do {
                try await services.storage.set(
                    key: "repos",
                    value: .array(stored.map { .string($0) })
                )
            } catch {
                return "Could not save this repository: \(error.localizedDescription)"
            }
        }

        showingAddRepoForm = false
        await enumerateRepos()
        return nil
    }

    private func loadManualOwnerRepos(services: SessionServices) async -> [String] {
        guard let value = try? await services.storage.get(namespace: id, key: "repos"),
              case .array(let values) = value
        else { return [] }

        var seen: Set<String> = []
        return values.compactMap { value in
            guard case .string(let stored) = value,
                  let (owner, repo) = parseAddedGitHubRepo(stored)
            else { return nil }
            let normalized = "\(owner)/\(repo)"
            guard seen.insert(normalized.lowercased()).inserted else { return nil }
            return normalized
        }
    }

    private func merge(autoRepos: [RepoInfo], manualOwnerRepos: [String]) -> [RepoInfo] {
        var merged: [RepoInfo] = []
        var seen: Set<String> = []

        for repo in autoRepos {
            guard seen.insert(repo.ownerRepo.lowercased()).inserted else { continue }
            merged.append(repo)
        }
        for ownerRepo in manualOwnerRepos {
            let key = ownerRepo.lowercased()
            guard seen.insert(key).inserted,
                  let url = URL(string: "https://github.com/\(ownerRepo)/pulls")
            else { continue }
            merged.append(RepoInfo(
                repoKey: nil,
                ownerRepo: ownerRepo,
                url: url,
                tabID: UUID()
            ))
        }
        return merged
    }

    private func publishRepos(_ repos: [RepoInfo]) {
        loadState = .ready(repos)
        if let model = BrowserSurface.model(forKey: id) {
            syncTabs(to: model, repos: repos)
        }
    }

    private func publishRepos(merging autoRepos: [RepoInfo], manualOwnerRepos: [String]) {
        publishRepos(merge(autoRepos: autoRepos, manualOwnerRepos: manualOwnerRepos))
    }

    /// Push one BrowserTab per repo into `model` via replaceTabs.
    /// Called from the BrowserSurface configure closure and from post-enumeration
    /// cache-hit sync.
    func syncTabs(to model: BrowserWidgetModel, repos: [RepoInfo]) {
        let tabs = repos.map { repo in
            BrowserTab(
                id: repo.tabID,
                url: repo.url,
                title: repo.ownerRepo,
                icon: "arrow.triangle.pull"
            )
        }
        model.replaceTabs(tabs)
    }
}

// MARK: - GitHubPRsRootView

/// Root view returned by `makeView`. Dispatches to the correct sub-view based
/// on the widget's observable `loadState`.
@MainActor
private struct GitHubPRsRootView: View {
    let widget: GitHubPRsWidget
    let services: SessionServices

    var body: some View {
        Group {
            switch widget.loadState {
            case .loading:
                GitHubPRsLoadingView()

            case .error(let message):
                GitHubPRsErrorView(
                    message: message,
                    onRetry: { Task { await widget.enumerateRepos() } },
                    onAdd: { widget.showingAddRepoForm = true }
                )

            case .ready(let repos):
                if repos.isEmpty {
                    GitHubPRsErrorView(
                        message: "No GitHub repositories found in the workspace.",
                        onRetry: { Task { await widget.enumerateRepos() } },
                        onAdd: { widget.showingAddRepoForm = true }
                    )
                } else {
                    GitHubPRsBrowserView(widget: widget, repos: repos)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { widget.showingAddRepoForm },
            set: { widget.showingAddRepoForm = $0 }
        )) {
            GitHubPRsAddRepoSheet(widget: widget)
        }
    }
}

// MARK: - Loading view

@MainActor
private struct GitHubPRsLoadingView: View {
    var body: some View {
        VStack(spacing: DT.s12) {
            GitHubBrandMark(size: 28)
            ProgressView()
                .controlSize(.regular)
            Text("Scanning workspace repositories…")
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DT.s24)
    }
}

// MARK: - Error view

/// Fail-loud error card. Never a blank tile.
@MainActor
private struct GitHubPRsErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: DT.s16) {
            GitHubBrandMark(size: 32)

            Text("GitHub PRs unavailable")
                .font(.system(size: DT.f13, weight: .medium))
                .foregroundStyle(DT.textPrimary)

            Text(message)
                .font(.system(size: DT.f11))
                .foregroundStyle(DT.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: DT.s8) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                Button("Add repository", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Browser view

/// Renders a BrowserSurface with one tab per workspace repo at its /pulls page.
/// The configure closure populates tabs via model.replaceTabs so BrowserSurface's
/// seeded first-tab is immediately replaced with the full tab set.
@MainActor
private struct GitHubPRsBrowserView: View {
    let widget: GitHubPRsWidget
    let repos: [RepoInfo]

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(
                url: repos[0].url,
                selector: "",
                dataStoreKey: "github",
                title: "GitHub PRs",
                icon: "arrow.triangle.pull"
            ),
            cacheKey: widget.id,
            configure: { [weak widget] model in
                guard let widget else { return }
                widget.syncTabs(to: model, repos: repos)
                model.onNewTab = { [weak widget] in
                    widget?.showingAddRepoForm = true
                }
            }
        )
    }
}

// MARK: - Add repository

@MainActor
private struct GitHubPRsAddRepoSheet: View {
    let widget: GitHubPRsWidget

    @State private var draft = ""
    @State private var errorMessage: String? = nil
    @State private var saving = false

    var body: some View {
        VStack(spacing: DT.s16) {
            GitHubBrandMark(size: 28)

            Text("Add GitHub repository")
                .font(.system(size: DT.f14, weight: .semibold))

            Text("Enter owner/repo or paste a github.com repository URL.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)

            TextField("owner/repo", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addRepo)
                .frame(width: 420)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: DT.s8) {
                Button("Cancel") {
                    widget.showingAddRepoForm = false
                }
                Button("Add repository", action: addRepo)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DT.s24)
        .frame(minWidth: 480)
    }

    private func addRepo() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            if let error = await widget.addManualRepo(draft) {
                errorMessage = error
            } else {
                draft = ""
            }
        }
    }
}

private struct GitHubBrandMark: View {
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let data = GitHubPRsReviewAgent.githubMarkPNG,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(DT.textTertiary)
        }
    }
}

// MARK: - Widget ABI entry points
//
// The two @_cdecl symbols the app's dlopen/dlsym loader expects.
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable — see
// reference_cdecl_mainactor_assumeisolated_pointer_sendable in MEMORY.md).

// MARK: - Review-queue header label (feat/home-labels .9)

/// PATH prefix so `gh` resolves under the widget's non-login shell (Homebrew /
/// MacPorts locations), mirroring the single GitHub widget's agent.
private let ghReviewPathPrefix =
    "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

/// GitHub mark (50x50 PNG) as base64 — leads the "to review" chip with the
/// brand logo. Sourced from the app's github-logo.png.
private let githubMarkPNGBase64 = "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"

/// Background agent for the GitHub PRs board: publishes a single "N to review"
/// header label — the count of OPEN PRs where the authenticated `gh` user is a
/// requested reviewer. Uses the same `services.shell` + `WidgetBackgroundAgent`
/// + `headerLabels` pattern as the single-PR widget's agent. Fail-soft: any `gh`
/// failure (missing / unauthenticated / nonzero exit / unparseable JSON) leaves
/// `headerLabels` empty — no error chip, no crash (AC15/AC16).
@Observable
@MainActor
final class GitHubPRsReviewAgent: WidgetBackgroundAgent {

    /// The board's contributed header labels. Empty until the first successful
    /// poll finds N > 0. @Observable so the host re-renders the strip on change.
    var headerLabels: [WidgetHeaderLabel] = []

    private var watchTask: Task<Void, Never>?

    func start(services: WidgetBackgroundServices) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            // Brief initial delay so the board renders before the first gh spawn.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.poll(services: services)
                try? await Task.sleep(nanoseconds: 120_000_000_000) // 2 minutes
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        headerLabels = []
    }

    private func poll(services: WidgetBackgroundServices) async {
        // Enumerate THIS workspace's GitHub repos (same rule as the widget's
        // view). Both counts are scoped to these repos — never a global list —
        // so the chips reflect the workspace you're in.
        let repos = await workspaceRepoSlugs(services: services)
        guard !repos.isEmpty else { headerLabels = []; return }
        let repoArgs = repos.map { "--repo \($0)" }.joined(separator: " ")

        // Two independent, workspace-scoped counts:
        //  • "to review" — open, NON-DRAFT PRs that explicitly request my review.
        //  • "in review" — ALL my open PRs (any draft state).
        let toReview = await count(
            services: services,
            query: "gh search prs --review-requested=@me --state=open --draft=false "
                + "--json url --limit 100 \(repoArgs)")
        let inReview = await count(
            services: services,
            query: "gh search prs --author=@me --state=open "
                + "--json url --limit 100 \(repoArgs)")

        // Each chip shows only when its count > 0 ("to review" hides at 0). Both
        // lead with the GitHub mark + brand color and carry NO url, so clicking
        // focuses the GitHub PRs widget (host-side) rather than opening a browser.
        var labels: [WidgetHeaderLabel] = []
        if let n = toReview, n > 0 { labels.append(Self.ghLabel(count: n, suffix: "to review")) }
        if let n = inReview, n > 0 { labels.append(Self.ghLabel(count: n, suffix: "in review")) }
        headerLabels = labels
    }

    /// Run a `gh search prs … --json url` query (with the PATH prefix) and return
    /// the result array's count, or nil on any failure (fail-soft — the caller
    /// omits that chip).
    private func count(services: WidgetBackgroundServices, query: String) async -> Int? {
        let cmd = "\(ghReviewPathPrefix) && \(query)"
        guard let result = try? await services.shell.run(command: cmd),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.count
    }

    /// A GitHub-branded header label: mark + dark brand color + "N PR(s) <suffix>".
    private static func ghLabel(count n: Int, suffix: String) -> WidgetHeaderLabel {
        let noun = n == 1 ? "PR" : "PRs"
        return WidgetHeaderLabel(
            text: "\(n) \(noun) \(suffix)",
            iconImageData: githubMarkPNG,
            brandColorHex: "#1F2328",   // GitHub dark
            tint: .neutral
        )
    }

    /// This workspace's GitHub `owner/repo` slugs — the workspace root if it is
    /// itself a repo, else its depth-1 git subdirs — mirroring the widget's own
    /// enumeration (services.shell cwd is the workspace root on Home). Deduped;
    /// empty when nothing resolves (→ no label).
    private func workspaceRepoSlugs(services: WidgetBackgroundServices) async -> [String] {
        let cmd = """
            \(ghReviewPathPrefix)
            if [ -d ".git" ]; then
              _url=$(git config --get remote.origin.url 2>/dev/null)
              [ -n "$_url" ] && printf '%s\\n' "$_url"
            else
              for _d in */; do
                [ -d "${_d}.git" ] || continue
                _url=$(git -C "${_d%/}" config --get remote.origin.url 2>/dev/null)
                [ -n "$_url" ] && printf '%s\\n' "$_url"
              done
            fi
            """
        guard let result = try? await services.shell.run(command: cmd),
              result.exitCode == 0 else { return [] }
        var slugs: [String] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let url = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let (owner, repo) = parseGitHubOwnerRepo(url) {
                slugs.append("\(owner)/\(repo)")
            }
        }
        return Array(Set(slugs))
    }

    /// The GitHub mark (50×50 PNG) embedded as base64 so the "to review" chip
    /// leads with the unambiguous brand logo instead of a generic SF Symbol.
    /// Decoded once; nil if decoding somehow fails (the chip then shows text
    /// only — still correct).
    static let githubMarkPNG: Data? = Data(base64Encoded: githubMarkPNGBase64)
}

extension GitHubPRsWidget: Work42WidgetBackground {
    /// Fresh agent per (session × widget) pair — the host owns the lifecycle.
    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        GitHubPRsReviewAgent()
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(GitHubPRsWidget())
    }
    return result
}
