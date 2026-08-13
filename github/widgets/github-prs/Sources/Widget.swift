// Widget.swift — github-prs widget (feat/plugings-implementation.17)
//
// REWORK: Replaces the old gh-list approach entirely.
//
// DESIGN (settled with Yan):
//   A HOME-surface browser widget that renders ONE TAB PER WORKSPACE REPOSITORY
//   at that repo's GitHub PRs page (https://github.com/<owner>/<repo>/pulls).
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
//   "Start code review session" — placement: [.palette, .actionArea].
//   isEnabled closure returns true ONLY when the active tab's URL (model.urlDraft)
//   matches a PR page (/pull/<N> path). Enabled = the button appears in the
//   action center and fires global.review.pr(url:).
//
// FAIL LOUD:
//   If no GitHub repos are found or the shell fails, renders a fail-loud error
//   card with a retry button — never a blank tile.
//
// NO STORAGE: Does not read or write any storage namespace.
// NO GH CLI: Uses only `git` for remote-URL resolution.
//
// WIDGET ID: "github-prs" (unchanged — the loader keyed this slug).

import Foundation
import Observation
import SwiftUI
import Work42WidgetKit

// MARK: - RepoInfo

/// One workspace git repository resolved to its GitHub PRs page URL.
struct RepoInfo: Sendable, Equatable {
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

/// Return true when `urlString` points to a GitHub PR page (path: /owner/repo/pull/<N>).
private func isGitHubPRPage(_ urlString: String) -> Bool {
    guard !urlString.isEmpty,
          let url = URL(string: urlString),
          let host = url.host,
          host.lowercased().hasSuffix("github.com")
    else { return false }
    let parts = url.pathComponents.filter { $0 != "/" }
    // Expected: ["owner", "repo", "pull", "N", ...]
    return parts.count >= 4 && parts[2].lowercased() == "pull" && Int(parts[3]) != nil
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

    /// Home-only: enumeration depends on workspace root being the shell's cwd.
    var enabledLayouts: Set<WidgetLayout> { [.home] }

    // MARK: - Observed state (drives the view)

    var loadState: GitHubPRsLoadState = .loading

    // MARK: - Intents

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "start-code-review",
                title: "Start Code Review Session",
                icon: "play.fill",
                keywords: ["review", "code review", "pr", "pull request", "session"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    let urlString = BrowserSurface.model(forKey: self.id)?.urlDraft ?? ""
                    return isGitHubPRPage(urlString)
                },
                perform: { [weak self] in
                    guard let self else { return }
                    let urlString = BrowserSurface.model(forKey: self.id)?.urlDraft ?? ""
                    guard isGitHubPRPage(urlString) else { return }
                    guard let svc = self.services else { return }
                    try await svc.intents.execute(
                        id: "global.review.pr",
                        params: ["url": .string(urlString)]
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
            loadState = .error(
                "Could not enumerate workspace repositories.\n\n" +
                error.localizedDescription +
                "\n\nEnsure git is installed and in PATH."
            )
            return
        }

        guard result.exitCode == 0 else {
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
                ownerRepo: "\(owner)/\(repo)",
                url: prsURL,
                tabID: UUID()
            ))
        }

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
            loadState = .ready(repos)
            // If the BrowserSurface model is already live (cache hit from a prior
            // activate/configure cycle), sync tabs immediately so the UI reflects
            // the freshly enumerated repos without waiting for a re-render.
            if let model = BrowserSurface.model(forKey: id) {
                syncTabs(to: model, repos: repos)
            }
        }
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
        switch widget.loadState {
        case .loading:
            GitHubPRsLoadingView()

        case .error(let message):
            GitHubPRsErrorView(message: message) {
                Task { await widget.enumerateRepos() }
            }

        case .ready(let repos):
            if repos.isEmpty {
                // Should not normally occur — enumerateRepos sets .error instead.
                GitHubPRsErrorView(
                    message: "No GitHub repositories found in the workspace.",
                    onRetry: { Task { await widget.enumerateRepos() } }
                )
            } else {
                GitHubPRsBrowserView(widget: widget, repos: repos)
            }
        }
    }
}

// MARK: - Loading view

@MainActor
private struct GitHubPRsLoadingView: View {
    var body: some View {
        VStack(spacing: DT.s12) {
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

    var body: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.amber)

            Text("GitHub PRs unavailable")
                .font(.system(size: DT.f13, weight: .medium))
                .foregroundStyle(DT.textPrimary)

            Text(message)
                .font(.system(size: DT.f11))
                .foregroundStyle(DT.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
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
            }
        )
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
        let cmd = "\(ghReviewPathPrefix) && gh search prs --review-requested=@me "
            + "--state=open --json url --limit 100"
        let result: WidgetShellResult
        do {
            result = try await services.shell.run(command: cmd)
        } catch {
            headerLabels = []           // spawn/timeout failure — fail soft
            return
        }
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            headerLabels = []           // gh missing / unauth / unparseable — fail soft
            return
        }
        let n = array.count
        guard n > 0 else {
            headerLabels = []
            return
        }
        let reviewQueueURL = URL(
            string: "https://github.com/pulls?q=is%3Aopen+is%3Apr+review-requested%3A%40me")
        let noun = n == 1 ? "Pull Request" : "Pull Requests"
        headerLabels = [
            WidgetHeaderLabel(
                text: "\(n) \(noun) to Review",
                iconImageData: Self.githubMarkPNG,
                tint: .warning,
                url: reviewQueueURL
            )
        ]
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
