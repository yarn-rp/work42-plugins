// Widget.swift — github pre-built widget (feat/generalizations-of-features.8).
//
// Renders one browser tab per entry in storage key `github/prs` (JSON array of
// {url, status, merged_at}), runs a background PR-watch loop entirely through
// `services.shell` (no direct Process calls), and delivers fingerprinted
// `[system event]`s via `task42 event` using the SAME fingerprint scheme as the
// deleted `PRWatchService` so existing `pending_updates` dedup entries carry over.
//
// RENDERING:
//   Empty state  → paste-URL form that writes to `github/prs` via storage.set.
//   One PR       → BrowserSurface (single tab, chrome-as-header via widget id key).
//   Two+ PRs     → BrowserSurface with replaceTabs for each entry; + wires to
//                  attach form; × calls detach (removes from storage).
//
// WATCHER:
//   activate() starts a Swift-concurrency Task that loops with a 60-second poll.
//   Each cycle: load github/prs → gh pr view + gh api inline comments (both via
//   services.shell) → diff → task42 event for new occurrences.
//   deactivate() cancels the task. Never blocks the main actor.
//
// STORAGE CONVENTION (SKILL.md):
//   Read any namespace: services.storage.get(namespace: "github", key: "prs")
//   Write own namespace (id = "github"): services.storage.set(key: "prs", …)
//   This widget's namespace IS "github" (id == folder slug == writable namespace).
//   services.storage.set(key: "prs", value:) writes directly to github/prs — no
//   shell indirection needed. Agents use `task42 storage set <id> github/prs ...`.

import Observation
import SwiftUI
import Work42WidgetKit

// MARK: - PR data model (storage schema)

/// One attached PR — matches the JSON schema stored in `github/prs`.
struct PREntry: Codable, Sendable, Equatable {
    var url: String
    var status: String          // "open" | "merged" | "closed"
    var merged_at: String?      // ISO-8601 or nil

    /// Parse a `WidgetJSONValue.array` from `github/prs` into typed entries.
    static func decode(from value: WidgetJSONValue) -> [PREntry] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item -> PREntry? in
            guard case .object(let obj) = item,
                  case .string(let url) = obj["url"] else { return nil }
            let status: String
            if case .string(let s) = obj["status"] { status = s } else { status = "open" }
            let mergedAt: String?
            if case .string(let m) = obj["merged_at"] { mergedAt = m } else { mergedAt = nil }
            return PREntry(url: url, status: status, merged_at: mergedAt)
        }
    }

    /// Encode `[PREntry]` → `WidgetJSONValue.array`.
    static func encode(_ entries: [PREntry]) -> WidgetJSONValue {
        .array(entries.map { entry in
            .object([
                "url":       .string(entry.url),
                "status":    .string(entry.status),
                "merged_at": entry.merged_at.map { .string($0) } ?? .null,
            ])
        })
    }
}

// MARK: - GitHub PR URL parsing

/// Minimal GitHub PR URL parser (no import of Task42Core / Flow42Core).
struct PRRef: Sendable {
    var owner: String
    var repo: String
    var number: Int
    var displayName: String { "\(owner)/\(repo)#\(number)" }
    var inlineCommentsEndpoint: String { "repos/\(owner)/\(repo)/pulls/\(number)/comments" }
}

func parseGitHubPRRef(_ urlString: String) -> PRRef? {
    guard let u = URL(string: urlString),
          let host = u.host, host.lowercased() == "github.com" else { return nil }
    let parts = u.pathComponents.filter { $0 != "/" }
    // /owner/repo/pull/N
    guard parts.count >= 4,
          parts[2].lowercased() == "pull",
          let n = Int(parts[3]) else { return nil }
    return PRRef(owner: parts[0], repo: parts[1], number: n)
}

// MARK: - Lightweight PR snapshot for the watch-loop diff

/// Minimal snapshot of a PR's watchable state — built by parsing `gh pr view --json` output.
/// Mirrors the relevant subset of Flow42Core's `GitHubPRSnapshot` without depending on it.
struct PRSnapshot: Sendable {
    var number: Int
    var state: String       // OPEN / MERGED / CLOSED
    var headRefOid: String
    var mergedAt: String?
    var author: String      // PR author's login ("" when absent)
    var reviews: [Review]
    var comments: [Comment]
    var reviewComments: [InlineComment]
    var checks: [Check]

    struct Review: Sendable {
        var id: String; var author: String; var state: String; var body: String
        var submittedAt: String?
    }
    struct Comment: Sendable {
        var id: String; var author: String; var body: String
    }
    struct InlineComment: Sendable {
        var id: String; var author: String; var body: String
        var path: String?; var line: Int?
    }
    struct Check: Sendable {
        var name: String; var conclusion: String; var isComplete: Bool
        var isFailure: Bool {
            isComplete && Check.failingConclusions.contains(conclusion)
        }
        var isSuccess: Bool {
            isComplete && (conclusion == "SUCCESS" || conclusion == "NEUTRAL" || conclusion == "SKIPPED")
        }
        static let failingConclusions: Set<String> = [
            "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE",
        ]
    }
}

/// Aggregate of one PR's header-worthy state — feeds the session-header
/// labels (`Work42WidgetHeaderLabels`). Derived from a `PRSnapshot` each
/// watch cycle; stored on the widget's `@Observable` state so the host
/// strip re-renders when CI or reviews move.
struct PRHeaderState: Sendable, Equatable {
    var author: String
    var checksTotal: Int
    var checksFailed: Int
    var checksPending: Int
    var approvals: Int
    var changesRequested: Bool

    init(from snap: PRSnapshot) {
        author = snap.author
        checksTotal = snap.checks.count
        checksFailed = snap.checks.filter(\.isFailure).count
        checksPending = snap.checks.filter { !$0.isComplete }.count
        // Latest review per author decides their standing (GitHub semantics:
        // a newer APPROVED supersedes an older CHANGES_REQUESTED and vice
        // versa; COMMENTED never changes standing).
        var latest: [String: PRSnapshot.Review] = [:]
        for r in snap.reviews where r.state == "APPROVED" || r.state == "CHANGES_REQUESTED" {
            if let existing = latest[r.author],
               (existing.submittedAt ?? "") > (r.submittedAt ?? "") { continue }
            latest[r.author] = r
        }
        approvals = latest.values.filter { $0.state == "APPROVED" }.count
        changesRequested = latest.values.contains { $0.state == "CHANGES_REQUESTED" }
    }
}

// MARK: - JSON parsing from gh output

/// Parse `gh pr view --json number,state,headRefOid,mergedAt,reviews,comments,statusCheckRollup`
/// output into a `PRSnapshot`. Returns nil on any structural decode failure.
func parsePRSnapshot(from jsonString: String, prURL: String) -> PRSnapshot? {
    guard let data = jsonString.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let number = (obj["number"] as? Int) ?? 0
    let state = ((obj["state"] as? String) ?? "UNKNOWN").uppercased()
    let headRefOid = (obj["headRefOid"] as? String) ?? ""
    let mergedAt = obj["mergedAt"] as? String
    let author = decodeLogin(obj, key: "author")

    // Reviews
    var reviews: [PRSnapshot.Review] = []
    if let rawReviews = obj["reviews"] as? [[String: Any]] {
        for r in rawReviews {
            let id: String
            if let s = r["id"] as? String, !s.isEmpty { id = s }
            else { id = "\(decodeLogin(r, key: "author"))|\((r["submittedAt"] as? String) ?? "")|\((r["state"] as? String) ?? "")" }
            reviews.append(PRSnapshot.Review(
                id: id,
                author: decodeLogin(r, key: "author"),
                state: ((r["state"] as? String) ?? "").uppercased(),
                body: (r["body"] as? String) ?? "",
                submittedAt: r["submittedAt"] as? String
            ))
        }
    }

    // Issue-level comments
    var comments: [PRSnapshot.Comment] = []
    if let rawComments = obj["comments"] as? [[String: Any]] {
        for c in rawComments {
            let id: String
            if let s = c["id"] as? String, !s.isEmpty { id = s }
            else if let i = c["id"] as? Int { id = String(i) }
            else { id = "\(decodeLogin(c, key: "author"))|\((c["createdAt"] as? String) ?? "")" }
            comments.append(PRSnapshot.Comment(
                id: id,
                author: decodeLogin(c, key: "author"),
                body: (c["body"] as? String) ?? ""
            ))
        }
    }

    // Status check rollup (heterogeneous CheckRun / StatusContext)
    var checks: [PRSnapshot.Check] = []
    if let rawChecks = obj["statusCheckRollup"] as? [[String: Any]] {
        for ch in rawChecks {
            if let status = ch["status"] as? String {
                // CheckRun
                let done = status.uppercased() == "COMPLETED"
                let conclusion = done ? ((ch["conclusion"] as? String) ?? "").uppercased() : ""
                let name = (ch["name"] as? String) ?? ""
                if !name.isEmpty {
                    checks.append(PRSnapshot.Check(name: name, conclusion: conclusion, isComplete: done && !conclusion.isEmpty))
                }
            } else if let state = ch["state"] as? String {
                // StatusContext
                let raw = state.uppercased()
                let pending = raw.isEmpty || raw == "PENDING" || raw == "EXPECTED"
                let name = (ch["context"] as? String) ?? ""
                if !name.isEmpty {
                    checks.append(PRSnapshot.Check(name: name, conclusion: pending ? "" : raw, isComplete: !pending))
                }
            }
        }
    }

    return PRSnapshot(
        number: number, state: state, headRefOid: headRefOid, mergedAt: mergedAt,
        author: author,
        reviews: reviews, comments: comments, reviewComments: [], checks: checks
    )
}

/// Parse `gh api repos/{owner}/{repo}/pulls/{N}/comments` (paginated) output
/// into inline review comments. Returns [] on any failure.
func parseInlineComments(from jsonString: String) -> [PRSnapshot.InlineComment] {
    guard let data = jsonString.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return arr.compactMap { c in
        let id: String
        if let i = c["id"] as? Int { id = String(i) }
        else if let s = c["id"] as? String, !s.isEmpty { id = s }
        else { return nil }
        let author: String
        if let user = c["user"] as? [String: Any], let login = user["login"] as? String {
            author = login
        } else {
            author = (c["login"] as? String) ?? ""
        }
        let path = c["path"] as? String
        let line = (c["line"] as? Int) ?? (c["original_line"] as? Int)
        return PRSnapshot.InlineComment(
            id: id,
            author: author,
            body: (c["body"] as? String) ?? "",
            path: path,
            line: line
        )
    }
}

/// Decode `author` from a `gh` object — either `{"author": {"login": "x"}}` or `{"author": "x"}`.
private func decodeLogin(_ obj: [String: Any], key: String) -> String {
    if let nested = obj[key] as? [String: Any], let login = nested["login"] as? String { return login }
    if let bare = obj[key] as? String { return bare }
    return ""
}

// MARK: - Fingerprint scheme (mirrors PRWatchEvent — must match for dedup carry-over)

/// Build the set of baseline fingerprints for a snapshot (same logic as
/// `PRWatchEvent.baselineFingerprints`). These are seeded in-memory on first
/// observation so the first poll doesn't replay the entire PR history.
func baselineFingerprints(for snap: PRSnapshot) -> Set<String> {
    var fps = Set<String>()
    for r in snap.reviews { fps.insert("review:\(r.id)") }
    for c in snap.comments { fps.insert("comment:\(c.id)") }
    for ic in snap.reviewComments { fps.insert("review-comment:\(ic.id)") }
    for ch in snap.checks where ch.isComplete { fps.insert("check:\(ch.name):\(ch.conclusion)") }
    if let ag = allGreenFingerprint(for: snap.checks) { fps.insert(ag) }
    return fps
}

func allGreenFingerprint(for checks: [PRSnapshot.Check]) -> String? {
    guard !checks.isEmpty, checks.allSatisfy(\.isComplete), checks.allSatisfy(\.isSuccess) else { return nil }
    let names = checks.map(\.name).sorted().joined(separator: ",")
    return "checks:all-green:\(names)"
}

/// Compare `old` → `new` and return new (fingerprint, message) pairs for
/// events that need delivery. Returns [] for baseline (prior == nil).
func newEvents(from old: PRSnapshot?, to new: PRSnapshot, ref: PRRef) -> [(String, String)] {
    guard let old else { return [] }
    var out: [(String, String)] = []
    let tag = "PR \(ref.displayName)"
    let pr = new.number

    // 1. State transitions (reopened handled via newEvents not terminal block)
    if old.state != new.state {
        switch new.state {
        case "MERGED":
            // NOTE: merged is handled by the terminal-state block that runs every poll.
            break
        case "CLOSED":
            // NOTE: closed is handled by the terminal-state block too.
            break
        case "OPEN":
            if old.state == "CLOSED" || old.state == "MERGED" {
                out.append(("state:reopened:\(pr)", "\(tag) was reopened."))
            }
        default: break
        }
    }

    // 2. New reviews
    let oldReviewIDs = Set(old.reviews.map(\.id))
    for r in new.reviews where !oldReviewIDs.contains(r.id) {
        let who = r.author.isEmpty ? "someone" : "@\(r.author)"
        let decision = humanReviewState(r.state)
        let snippet = bodySnippet(r.body)
        let body = snippet.isEmpty ? "." : " — \"\(snippet)\""
        out.append(("review:\(r.id)", "\(tag) review by \(who): \(decision)\(body)"))
    }

    // 3. New issue-level comments
    let oldCommentIDs = Set(old.comments.map(\.id))
    for c in new.comments where !oldCommentIDs.contains(c.id) {
        let who = c.author.isEmpty ? "someone" : "@\(c.author)"
        let snippet = bodySnippet(c.body)
        let body = snippet.isEmpty
            ? "new comment from \(who)."
            : "comment from \(who): \"\(snippet)\""
        out.append(("comment:\(c.id)", "\(tag) \(body)"))
    }

    // 4. New inline review comments
    let oldInlineIDs = Set(old.reviewComments.map(\.id))
    for ic in new.reviewComments where !oldInlineIDs.contains(ic.id) {
        let who = ic.author.isEmpty ? "someone" : "@\(ic.author)"
        let snippet = bodySnippet(ic.body)
        let anchor: String
        if let path = ic.path, !path.isEmpty {
            anchor = ic.line.map { " on \(path):\($0)" } ?? " on \(path)"
        } else {
            anchor = ""
        }
        let bodyStr = snippet.isEmpty ? "." : " — \"\(snippet)\""
        out.append(("review-comment:\(ic.id)", "\(tag) inline comment by \(who)\(anchor)\(bodyStr)"))
    }

    // 5. CI / status checks
    var oldConclusions: [String: String] = [:]
    for ch in old.checks where ch.isComplete { oldConclusions[ch.name] = ch.conclusion }
    for ch in new.checks where ch.isFailure {
        if oldConclusions[ch.name] != ch.conclusion {
            out.append(("check:\(ch.name):\(ch.conclusion)",
                        "\(tag) CI failed: \(ch.name) (\(ch.conclusion.lowercased())) — push a fix and CI will re-run."))
        }
    }
    if let newAG = allGreenFingerprint(for: new.checks) {
        let oldAG = allGreenFingerprint(for: old.checks)
        if newAG != oldAG {
            let count = new.checks.count
            out.append((newAG,
                        "\(tag) CI is all green — \(count) check\(count == 1 ? "" : "s") passed."))
        }
    }

    return out
}

/// The terminal-state event (merged/closed) — runs every poll so a missed delivery
/// self-heals. Returns nil for OPEN. `task42 event` deduplicates via `pending_updates`.
func terminalStateEvent(for snap: PRSnapshot, ref: PRRef) -> (String, String)? {
    let tag = "PR \(ref.displayName)"
    let pr = snap.number
    switch snap.state {
    case "MERGED": return ("state:merged:\(pr)", "\(tag) was merged.")
    case "CLOSED": return ("state:closed:\(pr)", "\(tag) was closed without merging.")
    default: return nil
    }
}

private func humanReviewState(_ state: String) -> String {
    switch state.uppercased() {
    case "APPROVED": return "APPROVED"
    case "CHANGES_REQUESTED": return "CHANGES_REQUESTED"
    case "COMMENTED": return "commented"
    case "DISMISSED": return "dismissed"
    case "PENDING": return "pending"
    default: return state.isEmpty ? "reviewed" : state
    }
}

private func bodySnippet(_ body: String, limit: Int = 140) -> String {
    let collapsed = body
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > limit else { return collapsed }
    let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit)
    return collapsed[..<cutoff].trimmingCharacters(in: .whitespaces) + "…"
}

// MARK: - Shell PATH enrichment

/// Prepend common Homebrew / local dirs to PATH for the gh + task42 shell invocations.
/// The app may be launched via Finder with a minimal PATH that omits these.
private let enrichedPathPrefix = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

// MARK: - GitHubPRWidget

/// The GitHub PR widget — pre-built, installed by default (feat/generalizations-of-features.8).
///
/// Widget id:  `github`  (must match folder slug — enforced by the loader)
/// Storage ns: reads `github/prs` via `services.storage.get(namespace: "github", key: "prs")`;
///             writes `github/prs` via `services.storage.set(key: "prs", value:)` — the
///             widget's writable namespace IS "github" so no shell indirection needed.
@Observable
@MainActor
final class GitHubPRWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "github"
    let title = "GitHub PR"
    let icon = "arrow.triangle.pull"

    // MARK: - Observed state (drives the view)

    /// Current PR list from `github/prs`. Updated by the watcher and attach/detach.
    var prs: [PREntry] = []
    /// Latest per-PR header aggregate (CI + review standing), keyed by PR
    /// url. Written each watch cycle; read by `headerLabels` so the session
    /// header strip re-renders live as CI/reviews move.
    var headerStates: [String: PRHeaderState] = [:]
    /// Non-nil when gh is unavailable / unauthenticated — shown in empty+degraded state.
    var ghDegradedMessage: String? = nil
    /// Drives the attach-sheet presentation.
    var showingAttachForm: Bool = false

    // MARK: - Selection state (drives the PR selection bubble + popover)

    /// Text currently selected in the active PR WebView. Empty = no bubble shown.
    var selectionText: String = ""
    /// View-space bounding rect of the selection (from the JS coordinate transform
    /// in `WebSectionView.selectionViewRect`). Used to position the + bubble.
    var selectionRect: CGRect = .zero
    /// The file path extracted from the GitHub diff DOM `data-path` for the current
    /// selection. Non-nil when the selection is inside a diff file section; nil for
    /// PR description / comment text outside the diff.
    var selectionFilePath: String? = nil
    /// Drives the `CommentComposerPopover` presentation over the + bubble.
    var showingSelectionPopover: Bool = false

    // MARK: - Internal (not observed)

    private var services: SessionServices?
    private var watchTask: Task<Void, Never>?

    /// The `BrowserWidgetModel` stored from the `configure:` closure of `BrowserSurface`.
    /// The selection overlay reads `model.activeLiveView?()` to wire `selectionHandler`
    /// on the current tab's `WebSectionLiveView` — without importing Work42App or
    /// Patrol42Core. Set to nil on `deactivate()`.
    var browserModel: BrowserWidgetModel?

    /// Last-seen snapshot per PR URL, keyed by URL string. Cleared on deactivate.
    private var lastSeen: [String: PRSnapshot] = [:]
    /// Baseline fingerprints per PR URL (seeded on first observation, never delivered).
    private var seededFingerprints: [String: Set<String>] = [:]
    /// Stable UUID → URL mapping so tab close → detach works.
    private var tabIDs: [String: UUID] = [:]

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.loadAndSyncPRs()
        }
        startWatcher(services: services)
    }

    func deactivate() {
        watchTask?.cancel()
        watchTask = nil
        services = nil
        browserModel = nil
        selectionText = ""
        selectionRect = .zero
        selectionFilePath = nil
        showingSelectionPopover = false
        lastSeen.removeAll()
        seededFingerprints.removeAll()
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PRWidgetMainView(widget: self, services: services))
    }

    // MARK: - Load PRs from storage

    func loadAndSyncPRs() async {
        guard let services else { return }
        do {
            if let value = try await services.storage.get(namespace: "github", key: "prs") {
                prs = PREntry.decode(from: value)
            } else {
                prs = []
            }
        } catch {
            // Storage unavailable (Home surface, no task, etc.) — stay empty.
            prs = []
        }
        syncTabs()
    }

    // MARK: - Tab sync

    /// Sync the BrowserSurface model's tab list from the current `prs` array.
    func syncTabs() {
        guard let model = BrowserSurface.model(forKey: id) else { return }
        let tabs: [BrowserTab] = prs.compactMap { entry -> BrowserTab? in
            guard let url = URL(string: entry.url) else { return nil }
            let ref = parseGitHubPRRef(entry.url)
            let label = ref?.displayName ?? entry.url
            return BrowserTab(id: stableTabID(for: entry.url), url: url, title: label, icon: "arrow.triangle.pull")
        }
        model.replaceTabs(tabs)
    }

    func stableTabID(for url: String) -> UUID {
        if let existing = tabIDs[url] { return existing }
        let new = UUID()
        tabIDs[url] = new
        return new
    }

    func urlForTabID(_ tabID: UUID) -> String? {
        tabIDs.first(where: { $0.value == tabID })?.key
    }

    // MARK: - Attach

    /// Validate and attach a new PR URL. Returns an error string on failure, nil on success.
    func attach(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "URL is empty." }
        guard parseGitHubPRRef(trimmed) != nil else {
            return "Not a GitHub PR URL. Expected https://github.com/owner/repo/pull/123."
        }
        guard URL(string: trimmed) != nil else { return "Not a valid web address." }
        guard !prs.contains(where: { $0.url == trimmed }) else { return nil }

        var updated = prs
        updated.append(PREntry(url: trimmed, status: "open", merged_at: nil))
        return await writePRs(updated)
    }

    // MARK: - Detach

    func detach(tabID: UUID) async {
        guard let urlString = urlForTabID(tabID) else { return }
        let updated = prs.filter { $0.url != urlString }
        tabIDs.removeValue(forKey: urlString)
        lastSeen.removeValue(forKey: urlString)
        seededFingerprints.removeValue(forKey: urlString)
        _ = await writePRs(updated)
    }

    // MARK: - Write PRs to storage

    /// Write the updated PR list to storage and refresh `self.prs`. Returns error string or nil.
    ///
    /// Uses `services.storage.set(key: "prs", value:)` which writes to THIS widget's own
    /// namespace — "github" (the widget id) — so the key `"prs"` lands at `github/prs`,
    /// exactly where the rest of the system reads it. No shell indirection needed.
    private func writePRs(_ updated: [PREntry]) async -> String? {
        guard let services else { return "Widget not active." }
        do {
            try await services.storage.set(key: "prs", value: PREntry.encode(updated))
        } catch {
            return "Failed to write PR list: \(error.localizedDescription)"
        }
        prs = updated
        syncTabs()
        return nil
    }

    // MARK: - Watcher

    private func startWatcher(services: SessionServices) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            // Brief initial delay so the view can render before the first poll.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.poll(services: services)
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
            }
        }
    }

    private func poll(services: SessionServices) async {
        // Load current PRs
        let currentPRs: [PREntry]
        do {
            if let value = try await services.storage.get(namespace: "github", key: "prs") {
                currentPRs = PREntry.decode(from: value)
            } else {
                currentPRs = []
            }
        } catch {
            return // Storage unavailable — skip this cycle
        }

        // Sync UI if the PR list changed out-of-band (CLI attach, agent, etc.)
        if currentPRs.map(\.url) != prs.map(\.url) {
            prs = currentPRs
            syncTabs()
        }

        guard !currentPRs.isEmpty else { return }

        var anyGhOk = false
        var prsUpdated = false
        var updatedPRs = currentPRs

        for (idx, entry) in currentPRs.enumerated() {
            guard let ref = parseGitHubPRRef(entry.url) else { continue }
            let key = entry.url

            // Fetch snapshot via gh
            let ghJSON = "\(enrichedPathPrefix) && gh pr view \"\(entry.url)\" --json number,state,headRefOid,mergedAt,author,reviews,comments,statusCheckRollup"
            let prResult: WidgetShellResult
            do {
                prResult = try await services.shell.run(command: ghJSON)
            } catch {
                continue // timeout or spawn failure — skip this PR
            }

            if prResult.exitCode != 0 {
                // gh unavailable or unauthenticated
                let stderr = prResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stderr.isEmpty {
                    ghDegradedMessage = "gh unavailable: \(stderr.prefix(200))"
                }
                continue
            }
            anyGhOk = true
            ghDegradedMessage = nil

            guard var snap = parsePRSnapshot(from: prResult.stdout, prURL: entry.url) else { continue }

            // Fetch inline review comments (secondary call, degrades gracefully)
            let inlineCmd = "\(enrichedPathPrefix) && gh api \"\(ref.inlineCommentsEndpoint)\" --paginate 2>/dev/null"
            if let inlineResult = try? await services.shell.run(command: inlineCmd),
               inlineResult.exitCode == 0 {
                let inline = parseInlineComments(from: inlineResult.stdout)
                snap = PRSnapshot(
                    number: snap.number, state: snap.state, headRefOid: snap.headRefOid,
                    mergedAt: snap.mergedAt, author: snap.author,
                    reviews: snap.reviews, comments: snap.comments,
                    reviewComments: inline, checks: snap.checks
                )
            }

            // Feed the session-header labels from this cycle's snapshot.
            let newHeaderState = PRHeaderState(from: snap)
            if headerStates[key] != newHeaderState {
                headerStates[key] = newHeaderState
            }

            let prior = lastSeen[key]

            if prior == nil {
                // First observation: seed baseline fingerprints without delivering.
                seededFingerprints[key] = baselineFingerprints(for: snap)
            } else {
                // Subsequent poll: diff and deliver new events.
                let events = newEvents(from: prior, to: snap, ref: ref)
                for (fp, msg) in events {
                    let baseline = seededFingerprints[key] ?? []
                    guard !baseline.contains(fp) else { continue }
                    await deliverEvent(services: services, message: msg, fingerprint: fp)
                }
            }

            // Terminal-state block runs every poll (self-healing, deduped by task42 event).
            if let (fp, msg) = terminalStateEvent(for: snap, ref: ref) {
                await deliverEvent(services: services, message: msg, fingerprint: fp)
                // Update status / merged_at in storage when state changes.
                let newStatus = snap.state == "MERGED" ? "merged" : "closed"
                if updatedPRs[idx].status != newStatus {
                    updatedPRs[idx].status = newStatus
                    updatedPRs[idx].merged_at = snap.mergedAt
                    prsUpdated = true
                }
            } else if entry.status != "open" && snap.state == "OPEN" {
                // Reopened
                updatedPRs[idx].status = "open"
                updatedPRs[idx].merged_at = nil
                prsUpdated = true
            }

            lastSeen[key] = snap
        }

        // Persist status/merged_at updates back to storage when they changed.
        // Uses services.storage.set (own namespace "github") — no shell indirection.
        if prsUpdated {
            do {
                try await services.storage.set(key: "prs", value: PREntry.encode(updatedPRs))
                prs = updatedPRs
            } catch {
                // Write failed — skip UI update; will retry on next poll.
            }
        }

        _ = anyGhOk // suppress unused warning
    }

    /// Deliver one event via the session's event command.
    ///
    /// - Task sessions: `task42 event "$WORK42_TASK_ID" '<msg>' --fingerprint '<fp>'`
    ///   (WORK42_TASK_ID is set by the shell context for task sessions).
    /// - Patrol sessions: `patrol42 event "$WORK42_PATROL_ID" '<msg>' --fingerprint '<fp>'`
    ///   (WORK42_PATROL_ID is set by the shell context for patrol sessions; see
    ///   WidgetCommandRunner.Context.patrolId and AC13 in feat/generalizations-of-features).
    ///
    /// When neither env var is set (Home surface or plain session), the command
    /// is skipped. Non-zero exit is logged but never crashes the watcher.
    private func deliverEvent(services: SessionServices, message: String, fingerprint: String) async {
        // Escape the message for sh single-quote embedding.
        let safeMsgParts = message.components(separatedBy: "'").joined(separator: "'\"'\"'")
        let safeFP = fingerprint.replacingOccurrences(of: "'", with: "'\"'\"'")
        // Dispatch to the right CLI based on which env var is set.
        // The `if [ -n ... ]` guard skips silently on Home/plain surfaces.
        let cmd = """
            \(enrichedPathPrefix)
            if [ -n "$WORK42_TASK_ID" ]; then
              task42 event "$WORK42_TASK_ID" '\(safeMsgParts)' --fingerprint '\(safeFP)'
            elif [ -n "$WORK42_PATROL_ID" ]; then
              patrol42 event "$WORK42_PATROL_ID" '\(safeMsgParts)' --fingerprint '\(safeFP)'
            fi
            """
        _ = try? await services.shell.run(command: cmd)
    }
}

// MARK: - PRWidgetMainView

/// Root view dispatched from `makeView`. Reads `widget.prs` (observable) and
/// renders either the empty-state form or the BrowserSurface multi-tab view.
@MainActor
private struct PRWidgetMainView: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    var body: some View {
        if widget.prs.isEmpty {
            PREmptyStateView(widget: widget, services: services)
        } else {
            PRBrowserView(widget: widget, services: services)
        }
    }
}

// MARK: - PRBrowserView

/// Renders the BrowserSurface with one tab per PR in `widget.prs`.
@MainActor
private struct PRBrowserView: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    /// Computes a stable key that changes whenever the active live view's
    /// identity changes — used as the `.task(id:)` key to re-wire the selection
    /// handler when the model becomes available or when the user switches tabs.
    private var selectionWireKey: String {
        guard let model = widget.browserModel else { return "none" }
        // Combine the model identity with the active tab id so the task re-runs
        // when the model first appears OR when a tab switch happens.
        let modelID = ObjectIdentifier(model).hashValue
        let tabID = model.activeTabId?.uuidString ?? "notab"
        return "\(modelID):\(tabID)"
    }

    private var firstURL: URL {
        widget.prs.first.flatMap { URL(string: $0.url) }
            ?? URL(string: "https://github.com")!
    }

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(
                url: firstURL,
                // No isolation selector: `.logged-in .application-main` blanks the
                // whole page when the store has no GitHub session (nothing matches),
                // leaving no way to reach the Sign in chrome. Render the full page.
                selector: "",
                // Shared cookie store with the regular Browser widget — sign in
                // once anywhere, every browser-based widget inherits the session.
                dataStoreKey: "browser",
                title: "GitHub PR",
                icon: "arrow.triangle.pull"
            ),
            cacheKey: widget.id,
            configure: { [weak widget] model in
                guard let widget else { return }
                // Store the model so PRSelectionOverlay can reach the live view.
                widget.browserModel = model
                // Sync all PR tabs (replace the seeded first tab from spec).
                widget.syncTabs()
                // + opens the attach form.
                model.onNewTab = { [weak widget] in
                    widget?.showingAttachForm = true
                }
                // × removes the PR from storage.
                model.onTabClosed = { [weak widget] tabID in
                    Task { await widget?.detach(tabID: tabID) }
                }
            }
        )
        // Re-sync tabs when prs changes (out-of-band attach/detach or storage update).
        .onChange(of: widget.prs.map(\.url)) { _, _ in
            widget.syncTabs()
        }
        .sheet(isPresented: Binding(
            get: { widget.showingAttachForm },
            set: { widget.showingAttachForm = $0 }
        )) {
            PRAttachSheet(widget: widget, services: services)
        }
        // Selection bubble + composer citation.
        // `selectionWireKey` reads `widget.browserModel?.activeTabId`, establishing
        // @Observable tracking so the task re-runs when either changes (model
        // becomes available, or the user switches tabs).
        .task(id: selectionWireKey) {
            // Clear any stale selection when the model changes or the tab switches
            // so a stale bubble from the previous tab never lingers.
            widget.selectionText = ""
            widget.selectionRect = .zero
            widget.selectionFilePath = nil
            widget.showingSelectionPopover = false

            guard let model = widget.browserModel else { return }
            // A brief async yield lets BrowserSurfaceReady's .onAppear complete
            // (which sets model.activeLiveView) before we try to read it.
            // The task inherits PRBrowserView's @MainActor isolation, so we remain
            // on the main actor throughout; the sleep just defers past the render cycle.
            try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
            guard !Task.isCancelled else { return }
            guard let live = model.activeLiveView?() else { return }
            // Wire: selection events → widget observable properties.
            // The widget is an @Observable @MainActor class, so writing to its
            // properties from this @MainActor closure is safe (no stale-capture risk).
            live.selectionHandler = { [weak widget] text, rect, filePath in
                widget?.selectionText = text
                widget?.selectionRect = rect
                widget?.selectionFilePath = filePath
                if text.isEmpty { widget?.showingSelectionPopover = false }
            }
        }
        .overlay(alignment: .topLeading) {
            PRSelectionBubble(widget: widget, services: services)
        }
    }
}

// MARK: - PRSelectionBubble

/// The + bubble overlay and `CommentComposerPopover` for PR text selection.
///
/// Appears over the BrowserSurface content area when the user selects text on
/// the PR page. Clicking the bubble opens `CommentComposerPopover`; on commit
/// the selection + user's note are attached to the chat composer via
/// `services.composer.attach` with a 'PR #N · <file>' source label.
///
/// All selection state lives in `GitHubPRWidget` (an @Observable class), so
/// writing from the `selectionHandler` closure is safe — no stale-capture risk.
@MainActor
private struct PRSelectionBubble: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    var body: some View {
        if !widget.selectionText.isEmpty {
            GeometryReader { proxy in
                let rect = widget.selectionRect
                // Clamp the bubble to inside the widget bounds.
                let bx = min(max(rect.midX + 12, 12), max(proxy.size.width - 12, 12))
                let by = min(max(rect.minY - 8, 8), max(proxy.size.height - 8, 8))
                let anchor = UnitPoint(
                    x: min(max(bx / max(proxy.size.width, 1), 0), 1),
                    y: min(max(by / max(proxy.size.height, 1), 0), 1)
                )
                ZStack {
                    // Invisible full-bleed layer carries the popover so
                    // `attachmentAnchor` updates correctly when the rect changes.
                    Color.clear
                        .allowsHitTesting(false)
                        .popover(
                            isPresented: Binding(
                                get: { widget.showingSelectionPopover },
                                set: { widget.showingSelectionPopover = $0 }
                            ),
                            attachmentAnchor: .point(anchor),
                            arrowEdge: .leading
                        ) {
                            CommentComposerPopover(
                                sourceLabel: prSourceLabel(filePath: widget.selectionFilePath),
                                excerpt: widget.selectionText,
                                onCommit: { body in
                                    commitComment(body: body)
                                },
                                isPresented: Binding(
                                    get: { widget.showingSelectionPopover },
                                    set: { widget.showingSelectionPopover = $0 }
                                )
                            )
                        }
                    Button {
                        widget.showingSelectionPopover = true
                    } label: {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DT.systemAccent)
                            .frame(width: 18, height: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(DT.systemAccent.opacity(0.18))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: bx, y: by)
                    .help("Attach selection to composer")
                }
            }
        }
    }

    // MARK: - Source label

    /// Human-readable label for the composer popover header.
    /// Degrades gracefully: "PR #N · Bar.swift" when both are available,
    /// "PR #N" with number but no file hint, "GitHub PR" as last resort.
    private func prSourceLabel(filePath: String?) -> String {
        let activeTabURL = widget.browserModel?.tabs
            .first(where: { $0.id == widget.browserModel?.activeTabId })?.url?.absoluteString
            ?? widget.browserModel?.tabs.first?.url?.absoluteString
        let ref = activeTabURL.flatMap { parseGitHubPRRef($0) }
        guard let ref else { return "GitHub PR" }
        if let hint = filePath, !hint.isEmpty {
            let filename = (hint as NSString).lastPathComponent
            return "PR #\(ref.number) · \(filename)"
        }
        return "PR #\(ref.number)"
    }

    // MARK: - Commit

    /// Attach the selection to the chat composer as a pending-comment citation,
    /// resolving the precise diff anchor first (Yan: "resolve the file and the
    /// lines" — the old built-in did this and the port must not lose it).
    ///
    /// Resolution: shell `gh pr diff <n>` via `services.shell` (cwd = the
    /// session worktree; the runner enriches PATH + GH_TOKEN) and match the
    /// selection against the unified diff with `PRDiffLocator` (a verbatim
    /// port of Patrol42Core.UnifiedDiffLocator — widgets can't link that
    /// module). The label becomes "PR #N · path/File.swift:L12–L18".
    /// Degrades in order: resolved anchor → DOM file hint → PR number →
    /// "GitHub PR". The attach happens after resolution (the SDK attach has
    /// no update-anchor path); the shell's own timeout bounds the wait.
    private func commitComment(body: String) {
        let text = widget.selectionText
        let fileHint = widget.selectionFilePath
        let fallbackLabel = prSourceLabel(filePath: fileHint)
        let ref = activePRRef()
        // Clear selection state immediately for responsiveness.
        widget.selectionText = ""
        widget.selectionRect = .zero
        widget.selectionFilePath = nil
        let services = services
        Task { @MainActor in
            var label = fallbackLabel
            // `--repo owner/repo` — the session cwd is the multi-repo patrol
            // CONTAINER (not a git repo), so gh cannot infer the repo from
            // the working directory; a bare `gh pr diff <n>` fails there.
            if let ref,
               let result = try? await services.shell.run(
                   command: "\(enrichedPathPrefix) && gh pr diff \(ref.number) --repo \(ref.owner)/\(ref.repo)"
               ),
               result.exitCode == 0,
               let anchor = PRDiffLocator.locate(
                   patch: result.stdout, fileHint: fileHint, selection: text
               ) {
                let lines = anchor.startLine == anchor.endLine
                    ? "L\(anchor.startLine)"
                    : "L\(anchor.startLine)–L\(anchor.endLine)"
                label = "PR #\(ref.number) · \(anchor.filePath):\(lines)"
            }
            try? await services.composer.attach(
                sourceLabel: label,
                excerpt: text,
                body: body
            )
        }
    }

    /// The `PRRef` of the ACTIVE browser tab (fallback: first tab).
    private func activePRRef() -> PRRef? {
        let activeTabURL = widget.browserModel?.tabs
            .first(where: { $0.id == widget.browserModel?.activeTabId })?.url?.absoluteString
            ?? widget.browserModel?.tabs.first?.url?.absoluteString
        return activeTabURL.flatMap { parseGitHubPRRef($0) }
    }
}

// MARK: - PREmptyStateView

@MainActor
private struct PREmptyStateView: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.textTertiary)

            Text("No PR yet")
                .font(.system(size: DT.f13, weight: .medium))

            if let degraded = widget.ghDegradedMessage {
                Text(degraded)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            } else {
                Text("Once the worker pushes a branch, the PR link lands here. Or paste a GitHub PR URL to track it now — the PR is rendered inside Work42, sign in to GitHub once and the session is kept.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: DT.s8) {
                TextField("https://github.com/owner/repo/pull/123", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAttach)

                Button("Open in Work42", action: submitAttach)
                    .disabled(attaching || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 360)

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitAttach() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !attaching else { return }
        attaching = true
        errorMessage = nil
        Task { @MainActor in
            defer { attaching = false }
            if let err = await widget.attach(urlString: trimmed) {
                errorMessage = err
            } else {
                draftURL = ""
            }
        }
    }
}

// MARK: - PRAttachSheet

/// Modal sheet shown when the `+` button is pressed in the chrome row.
@MainActor
private struct PRAttachSheet: View {
    let widget: GitHubPRWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            Text("Attach a GitHub PR")
                .font(.system(size: DT.f14, weight: .semibold))

            Text("Paste a GitHub PR URL. A new tab is added and the PR is embedded.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://github.com/owner/repo/pull/123", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAttach)

                Button("Attach", action: submitAttach)
                    .disabled(attaching || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 360)

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button("Cancel") {
                widget.showingAttachForm = false
                draftURL = ""
                errorMessage = nil
            }
            .buttonStyle(.bordered)
        }
        .padding(DT.s24)
        .frame(minWidth: 420)
    }

    private func submitAttach() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !attaching else { return }
        attaching = true
        errorMessage = nil
        Task { @MainActor in
            defer { attaching = false }
            if let err = await widget.attach(urlString: trimmed) {
                errorMessage = err
            } else {
                draftURL = ""
                widget.showingAttachForm = false
            }
        }
    }
}

// MARK: - Session header labels (Work42WidgetHeaderLabels)

/// Labels the widget contributes to the session header's metadata strip:
/// author + CI standing + review standing for the primary (first) attached
/// PR. Vendor knowledge stays here — the host renders the chips without
/// knowing what "CI" or "approvals" mean. (The host's old PROwnerChip and
/// its inline gh author fetch were REMOVED in favor of this label.)
extension GitHubPRWidget: Work42WidgetHeaderLabels {
    var headerLabels: [WidgetHeaderLabel] {
        // Label the FIRST PR only — patrol sessions have one primary PR;
        // labeling a whole multi-PR set would spam the strip.
        guard let entry = prs.first, let st = headerStates[entry.url] else { return [] }
        var labels: [WidgetHeaderLabel] = []

        if !st.author.isEmpty {
            labels.append(WidgetHeaderLabel(
                text: "@\(st.author)", systemIcon: "person.crop.circle",
                tint: .neutral, url: URL(string: "https://github.com/\(st.author)")
            ))
        }

        if st.checksTotal > 0 {
            let checksURL = URL(string: "\(entry.url)/checks")
            if st.checksFailed > 0 {
                labels.append(WidgetHeaderLabel(
                    text: st.checksFailed == 1 ? "CI: 1 failing" : "CI: \(st.checksFailed) failing",
                    systemIcon: "xmark.circle.fill", tint: .failure, url: checksURL
                ))
            } else if st.checksPending > 0 {
                labels.append(WidgetHeaderLabel(
                    text: "CI running", systemIcon: "clock.fill",
                    tint: .warning, url: checksURL
                ))
            } else {
                labels.append(WidgetHeaderLabel(
                    text: "CI passing", systemIcon: "checkmark.circle.fill",
                    tint: .success, url: checksURL
                ))
            }
        }

        if st.changesRequested {
            labels.append(WidgetHeaderLabel(
                text: "Changes requested", systemIcon: "exclamationmark.bubble.fill",
                tint: .warning, url: URL(string: entry.url)
            ))
        } else if st.approvals > 0 {
            labels.append(WidgetHeaderLabel(
                text: st.approvals == 1 ? "1 approval" : "\(st.approvals) approvals",
                systemIcon: "checkmark.seal.fill", tint: .success,
                url: URL(string: entry.url)
            ))
        }

        return labels
    }
}

// MARK: - Widget entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects.
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable — see
// reference_cdecl_mainactor_assumeisolated_pointer_sendable in MEMORY.md).

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(GitHubPRWidget())
    }
    return result
}


// MARK: - PRDiffLocator (ported from Patrol42Core.UnifiedDiffLocator)
//
// Verbatim port of `Patrol42Core.UnifiedDiffLocator` — widget dylibs link only
// Work42UI + Work42WidgetKit, so the pure locator algorithm is duplicated here.
// If the Patrol42Core original changes its match/ambiguity contract, keep this
// copy in sync. Contract summary: parse the unified diff file-by-file and
// hunk-by-hunk; match the whitespace-trimmed selection lines as a contiguous
// run; report new-side numbers for added runs, old-side for removed, new-side
// (fallback old) for mixed/context; fileHint restricts the search
// suffix-tolerantly; ambiguous multi-file matches with no hint return nil.

private nonisolated enum PRDiffChangeKind: String, Sendable, Equatable {
    case added, removed, context
}

private nonisolated struct PRDiffAnchor: Sendable, Equatable {
    let filePath: String
    let startLine: Int
    let endLine: Int
    let change: PRDiffChangeKind
}

private nonisolated enum PRDiffLocator {

    static func locate(patch: String, fileHint: String?, selection: String) -> PRDiffAnchor? {
        let selectionLines = selection
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !selectionLines.isEmpty else { return nil }

        let files = parse(patch: patch)
        guard !files.isEmpty else { return nil }

        let candidates: [ParsedFile]
        if let fileHint, !fileHint.trimmingCharacters(in: .whitespaces).isEmpty {
            let hinted = files.filter { pathMatchesHint($0.path, hint: fileHint) }
            candidates = hinted.isEmpty ? files : hinted
        } else {
            candidates = files
        }

        var matches: [PRDiffAnchor] = []
        for file in candidates {
            for anchor in matchesIn(file: file, selectionLines: selectionLines) {
                matches.append(anchor)
                if fileHint != nil { return anchor }
            }
        }

        if matches.isEmpty { return nil }
        if matches.count == 1 { return matches[0] }
        let distinct = Set(matches.map { "\($0.filePath)|\($0.startLine)|\($0.endLine)|\($0.change.rawValue)" })
        if distinct.count == 1 { return matches[0] }
        return nil
    }

    private struct BodyLine {
        let kind: PRDiffChangeKind
        let content: String
        let oldLine: Int?
        let newLine: Int?
    }

    private struct ParsedFile {
        var path: String
        var lines: [BodyLine]
    }

    private static func parse(patch: String) -> [ParsedFile] {
        var files: [ParsedFile] = []
        var current: ParsedFile?
        var oldCounter = 0
        var newCounter = 0
        var inHunk = false

        func flush() {
            if let c = current { files.append(c) }
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("diff --git ") {
                flush()
                current = ParsedFile(path: pathFromDiffGit(rawLine) ?? "", lines: [])
                inHunk = false
                continue
            }
            if rawLine.hasPrefix("+++ ") {
                if let p = pathFromPlusPlus(rawLine), current != nil {
                    current?.path = p
                }
                inHunk = false
                continue
            }
            if rawLine.hasPrefix("--- ") {
                inHunk = false
                continue
            }
            if rawLine.hasPrefix("@@") {
                if let (oldStart, newStart) = parseHunkHeader(rawLine) {
                    oldCounter = oldStart
                    newCounter = newStart
                    inHunk = true
                } else {
                    inHunk = false
                }
                continue
            }
            guard inHunk, current != nil else { continue }
            if rawLine.hasPrefix("\\") { continue }

            guard let marker = rawLine.first else {
                current?.lines.append(BodyLine(kind: .context, content: "",
                                               oldLine: oldCounter, newLine: newCounter))
                oldCounter += 1
                newCounter += 1
                continue
            }
            let body = String(rawLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            switch marker {
            case "+":
                current?.lines.append(BodyLine(kind: .added, content: body,
                                               oldLine: nil, newLine: newCounter))
                newCounter += 1
            case "-":
                current?.lines.append(BodyLine(kind: .removed, content: body,
                                               oldLine: oldCounter, newLine: nil))
                oldCounter += 1
            case " ":
                current?.lines.append(BodyLine(kind: .context, content: body,
                                               oldLine: oldCounter, newLine: newCounter))
                oldCounter += 1
                newCounter += 1
            default:
                inHunk = false
            }
        }
        flush()
        return files
    }

    /// Edge-tolerant line comparison: a browser drag routinely starts/ends
    /// mid-word, so the FIRST selection line may be a clipped tail of its diff
    /// line (suffix match) and the LAST a clipped head (prefix match). Middle
    /// lines must match exactly. Single-line selections use containment when
    /// long enough to be unambiguous (>= 8 chars), exact equality otherwise.
    /// (Divergence from the Patrol42Core original, which required exact lines —
    /// real selections kept failing on clipped edges.)
    private static func lineMatches(
        _ diffLine: String, _ selLine: String, index j: Int, count n: Int
    ) -> Bool {
        if n == 1 {
            if selLine.count >= 8 { return diffLine.contains(selLine) }
            return diffLine == selLine
        }
        if j == 0 { return diffLine == selLine || diffLine.hasSuffix(selLine) }
        if j == n - 1 { return diffLine == selLine || diffLine.hasPrefix(selLine) }
        return diffLine == selLine
    }

    private static func matchesIn(file: ParsedFile, selectionLines: [String]) -> [PRDiffAnchor] {
        let n = selectionLines.count
        let body = file.lines
        guard body.count >= n else { return [] }
        var results: [PRDiffAnchor] = []

        var i = 0
        while i + n <= body.count {
            var matched = true
            for j in 0..<n where !lineMatches(body[i + j].content, selectionLines[j], index: j, count: n) {
                matched = false
                break
            }
            if matched {
                let run = Array(body[i..<(i + n)])
                if let anchor = anchor(forRun: run, path: file.path) {
                    results.append(anchor)
                }
                i += n
            } else {
                i += 1
            }
        }
        return results
    }

    private static func anchor(forRun run: [BodyLine], path: String) -> PRDiffAnchor? {
        guard !run.isEmpty else { return nil }
        let allAdded = run.allSatisfy { $0.kind == .added }
        let allRemoved = run.allSatisfy { $0.kind == .removed }

        if allAdded {
            let nums = run.compactMap { $0.newLine }
            guard let lo = nums.min(), let hi = nums.max() else { return nil }
            return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .added)
        }
        if allRemoved {
            let nums = run.compactMap { $0.oldLine }
            guard let lo = nums.min(), let hi = nums.max() else { return nil }
            return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .removed)
        }
        let newNums = run.compactMap { $0.newLine }
        if let lo = newNums.min(), let hi = newNums.max() {
            return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .context)
        }
        let oldNums = run.compactMap { $0.oldLine }
        guard let lo = oldNums.min(), let hi = oldNums.max() else { return nil }
        return PRDiffAnchor(filePath: path, startLine: lo, endLine: hi, change: .context)
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        guard let firstAt = line.range(of: "@@") else { return nil }
        let afterFirst = line[firstAt.upperBound...]
        guard let secondAt = afterFirst.range(of: "@@") else { return nil }
        let inner = afterFirst[..<secondAt.lowerBound].trimmingCharacters(in: .whitespaces)
        var oldStart: Int?
        var newStart: Int?
        for token in inner.split(separator: " ") {
            if token.hasPrefix("-") {
                oldStart = leadingInt(String(token.dropFirst()))
            } else if token.hasPrefix("+") {
                newStart = leadingInt(String(token.dropFirst()))
            }
        }
        guard let o = oldStart, let nw = newStart else { return nil }
        return (o, nw)
    }

    private static func leadingInt(_ s: String) -> Int? {
        let head = s.prefix { $0.isNumber }
        return Int(head)
    }

    private static func pathFromDiffGit(_ line: String) -> String? {
        guard let bRange = line.range(of: " b/") else { return nil }
        let path = String(line[bRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func pathFromPlusPlus(_ line: String) -> String? {
        var rest = String(line.dropFirst(4))
        if let tab = rest.firstIndex(of: "\t") {
            rest = String(rest[..<tab])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest == "/dev/null" { return nil }
        if rest.hasPrefix("b/") { rest = String(rest.dropFirst(2)) }
        return rest.isEmpty ? nil : rest
    }

    private static func pathMatchesHint(_ path: String, hint: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        let h = hint.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || h.isEmpty { return false }
        if p == h { return true }
        if p.hasSuffix(h) || h.hasSuffix(p) { return true }
        let pLast = (p as NSString).lastPathComponent
        let hLast = (h as NSString).lastPathComponent
        if pLast == hLast { return true }
        return false
    }
}
