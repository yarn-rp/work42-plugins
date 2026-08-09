// Widget.swift — github-prs widget (feat/plugings-implementation.10)
//
// Lists the current user's open GitHub pull requests via
// `gh pr list --author @me --state open --json ...`
// and renders one row per PR with a "Start code review session" button.
//
// RENDERING:
//   Loading state  → progress spinner + label.
//   Loaded, empty  → friendly "no open PRs" card.
//   Loaded, PRs    → scrollable list; one row per PR:
//                    repo+number heading, title, branch, "Start code review
//                    session" button. Button fires global.review.pr(url:).
//   gh error       → fail-loud error card naming the gh auth remedy.
//
// FETCH:
//   activate() triggers the initial fetch.
//   A declared Refresh intent (palette + action-area icon button) re-runs it.
//   No background poll — this widget is fetch-on-demand only.
//
// INTENT:
//   "Start code review session" calls:
//     services.intents.execute(id: "global.review.pr", params: ["url": .string(prURL)])
//   (intent id finalized in subtask .7, committed 936cc7d)
//
// STORAGE:
//   None — this widget reads live from gh on every refresh.
//   It does NOT write to or depend on github/prs storage.
//
// GH DEPENDENCY:
//   Requires `gh` CLI installed and authenticated (`gh auth login`).
//   Missing or unauthenticated gh → fail-loud error card, never a blank tile.

import Observation
import SwiftUI
import Work42WidgetKit

// MARK: - Data model

/// One open PR from `gh pr list`.
struct OpenPREntry: Sendable, Identifiable, Equatable {
    var id: String { url }
    var number: Int
    var title: String
    var url: String
    var headRefName: String
    var repoNameWithOwner: String
}

// MARK: - JSON parsing

/// Parse `gh pr list --json number,title,url,headRefName,repository` output
/// into typed `OpenPREntry` values. Returns [] on any structural failure.
func parseOpenPRs(from jsonString: String) -> [OpenPREntry] {
    guard let data = jsonString.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }

    return arr.compactMap { obj -> OpenPREntry? in
        guard let number = obj["number"] as? Int,
              let title = obj["title"] as? String,
              let url = obj["url"] as? String,
              !url.isEmpty
        else { return nil }

        let headRefName = (obj["headRefName"] as? String) ?? ""
        let repoNameWithOwner: String
        if let repo = obj["repository"] as? [String: Any],
           let nwo = repo["nameWithOwner"] as? String, !nwo.isEmpty {
            repoNameWithOwner = nwo
        } else {
            // Fall back to extracting owner/repo from the URL path.
            if let u = URL(string: url) {
                let parts = u.pathComponents.filter { $0 != "/" }
                if parts.count >= 2 {
                    repoNameWithOwner = "\(parts[0])/\(parts[1])"
                } else {
                    repoNameWithOwner = ""
                }
            } else {
                repoNameWithOwner = ""
            }
        }

        return OpenPREntry(
            number: number,
            title: title,
            url: url,
            headRefName: headRefName,
            repoNameWithOwner: repoNameWithOwner
        )
    }
}

// MARK: - Shell PATH enrichment

/// Prepend common Homebrew / local dirs to PATH for gh invocations.
/// Mirrors the same constant in the existing github widget.
private let enrichedPathPrefix = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

// MARK: - Widget state

/// The three display states the widget can be in.
enum GitHubPRsState: Sendable, Equatable {
    case loading
    case loaded([OpenPREntry])
    case ghError(String)
}

// MARK: - GitHubPRsWidget

/// Widget id: `github-prs`. Lists the user's open GitHub PRs and lets them
/// launch a code-review session in one click.
@Observable
@MainActor
final class GitHubPRsWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "github-prs"
    let title = "GitHub PRs"
    let icon = "arrow.triangle.pull"

    // MARK: - Observed state (drives the view)

    var state: GitHubPRsState = .loading

    // MARK: - Intents

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "refresh",
                title: "Refresh PR List",
                icon: "arrow.clockwise",
                keywords: ["refresh", "reload", "update", "pull requests"],
                placement: [.palette, .actionArea],
                actionAreaStyle: .icon,
                perform: { [weak self] in
                    await self?.fetchPRs()
                }
            ),
        ]
    }

    // MARK: - Internal

    private var services: SessionServices?

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.fetchPRs()
        }
    }

    func deactivate() {
        services = nil
        state = .loading
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(GitHubPRsRootView(widget: self, services: services))
    }

    // MARK: - Fetch

    /// Fetch the current user's open PRs via `gh pr list`.
    /// Updates `state` on the main actor — the view re-renders automatically.
    func fetchPRs() async {
        guard let services else { return }
        state = .loading

        let cmd = "\(enrichedPathPrefix) && gh pr list --author @me --state open --json number,title,url,headRefName,repository --limit 50"
        let result: WidgetShellResult
        do {
            result = try await services.shell.run(command: cmd)
        } catch {
            state = .ghError(
                "gh could not be launched: \(error.localizedDescription)\n" +
                "Remedy: install the GitHub CLI with `brew install gh`, then run `gh auth login`."
            )
            return
        }

        guard result.exitCode == 0 else {
            let raw = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let remedy = ghRemedy(for: raw)
            let detail = raw.isEmpty
                ? "gh exited with code \(result.exitCode)."
                : String(raw.prefix(300))
            state = .ghError("\(detail)\n\nRemedy: \(remedy)")
            return
        }

        state = .loaded(parseOpenPRs(from: result.stdout))
    }

    /// Infer a human-readable remedy from gh's stderr output.
    private func ghRemedy(for stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("not logged") || lower.contains("auth") || lower.contains("token") || lower.contains("login") {
            return "Run `gh auth login` in a terminal to authenticate the GitHub CLI."
        }
        if lower.contains("command not found") || lower.contains("no such file") {
            return "Install the GitHub CLI: `brew install gh`, then run `gh auth login`."
        }
        return "Run `gh auth login` to authenticate, or verify that `gh` is installed (brew install gh)."
    }
}

// MARK: - GitHubPRsRootView

/// Root view dispatched from `makeView`. Renders a header row with a Refresh
/// button and the content area (loading / empty / list / error).
@MainActor
private struct GitHubPRsRootView: View {
    let widget: GitHubPRsWidget
    let services: SessionServices

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.surface)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Open Pull Requests")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(DT.textPrimary)
            Spacer()
            Button {
                Task { await widget.fetchPRs() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(isLoading ? DT.textTertiary : DT.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh PR list")
            .disabled(isLoading)
        }
        .padding(.horizontal, DT.s16)
        .padding(.vertical, DT.s12)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch widget.state {
        case .loading:
            GitHubPRsLoadingView()
        case .loaded(let prs):
            if prs.isEmpty {
                GitHubPRsEmptyView()
            } else {
                GitHubPRsListView(prs: prs, services: services)
            }
        case .ghError(let message):
            GitHubPRsErrorView(message: message) {
                Task { await widget.fetchPRs() }
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = widget.state { return true }
        return false
    }
}

// MARK: - Loading view

@MainActor
private struct GitHubPRsLoadingView: View {
    var body: some View {
        VStack(spacing: DT.s12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading pull requests…")
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DT.s24)
    }
}

// MARK: - Empty view

@MainActor
private struct GitHubPRsEmptyView: View {
    var body: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.green)
            Text("No open pull requests")
                .font(.system(size: DT.f13, weight: .medium))
                .foregroundStyle(DT.textPrimary)
            Text("You have no open PRs authored by you right now. When you open a pull request on GitHub it will appear here.")
                .font(.system(size: DT.f11))
                .foregroundStyle(DT.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Error view

@MainActor
private struct GitHubPRsErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.amber)

            Text("GitHub CLI unavailable")
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

// MARK: - PR list view

@MainActor
private struct GitHubPRsListView: View {
    let prs: [OpenPREntry]
    let services: SessionServices

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(prs) { pr in
                    PRRowView(pr: pr, services: services)
                    if pr.id != prs.last?.id {
                        Divider()
                            .padding(.horizontal, DT.s16)
                    }
                }
            }
        }
    }
}

// MARK: - PR row view

/// One row in the PR list. Shows repo, number, title, branch, and the
/// "Start code review session" button.
@MainActor
private struct PRRowView: View {
    let pr: OpenPREntry
    let services: SessionServices

    @State private var launching = false
    @State private var launchError: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            // Icon
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.textTertiary)
                .frame(width: 16)
                .padding(.top, 2)

            // PR metadata
            VStack(alignment: .leading, spacing: DT.s4) {
                // Repo + number eyebrow
                HStack(spacing: DT.s4) {
                    if !pr.repoNameWithOwner.isEmpty {
                        Text(pr.repoNameWithOwner)
                            .font(.system(size: DT.f10, weight: .medium))
                            .foregroundStyle(DT.textTertiary)
                    }
                    Text("#\(pr.number)")
                        .font(.system(size: DT.f10, weight: .medium))
                        .foregroundStyle(DT.textTertiary)
                }

                // Title
                Text(pr.title)
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(DT.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Branch name
                if !pr.headRefName.isEmpty {
                    Text(pr.headRefName)
                        .font(.system(size: DT.f10))
                        .foregroundStyle(DT.textTertiary)
                        .lineLimit(1)
                }

                // Launch error (shown inline below the PR title)
                if let err = launchError {
                    Text(err)
                        .font(.system(size: DT.f10))
                        .foregroundStyle(DT.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DT.s8)

            // "Start code review session" button
            Button(action: launchReview) {
                HStack(spacing: DT.s4) {
                    if launching {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: DT.f9, weight: .semibold))
                    }
                    Text("Start code review session")
                        .font(.system(size: DT.f10, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, DT.s8)
                .padding(.vertical, DT.s4)
                .background(
                    RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                        .fill(DT.systemAccent.opacity(0.12))
                )
                .foregroundStyle(DT.systemAccent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(launching)
            .help("Open or re-focus a code review session for this PR")
        }
        .padding(.horizontal, DT.s16)
        .padding(.vertical, DT.s12)
    }

    /// Fire the `global.review.pr` intent with this PR's URL.
    private func launchReview() {
        guard !launching else { return }
        launching = true
        launchError = nil
        let prURL = pr.url
        Task { @MainActor in
            defer { launching = false }
            do {
                try await services.intents.execute(
                    id: "global.review.pr",
                    params: ["url": .string(prURL)]
                )
            } catch {
                launchError = "Could not start session: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Widget ABI entry points

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
