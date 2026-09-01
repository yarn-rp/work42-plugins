// Widget.swift — jira pre-built widget (feat/generalizations-of-features.6).
//
// Renders the Jira issue(s) linked to the current session through a
// BrowserSurface with ONE TAB PER ISSUE — mirroring the GitHub PR widget's
// multiple-PR support. Two states, driven by whether any issue is stored:
//
//   EMPTY state    — paste-URL form. On submit, appends the issue to jira/issues.
//
//   ASSIGNED state — BrowserSurface with one tab per attached issue:
//                      selector:     "" (full page — an isolation selector
//                                     blanks the whole page when the user
//                                     isn't signed in yet, since nothing matches)
//                      dataStoreKey: "browser" (cookies shared with the Browser widget)
//                      cacheKey:     id ("jira")
//                    The chrome's `+` opens an attach sheet; a tab's `×` detaches.
//
// STORAGE (widget id "jira" == namespace "jira"):
//   jira/issues — JSON array of { url, key } (the source of truth).
//   Legacy jira/url + jira/key (single-issue) are migrated into a one-element
//   jira/issues list on first load, then deleted.
//
// Jira key parsing (reimplemented here from the deleted Task42Core.JiraTicket):
//   Regex-free: split the URL path on "/" and look for a component matching
//   [A-Z][A-Z0-9]+-[0-9]+, preferring the component that follows /browse/ or
//   /issues/. Handles every Atlassian Cloud URL shape.

import AppKit
import Observation
import SwiftUI
import Work42WidgetKit

private let jiraMarkPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAARGVYSWZNTQAqAAAACAABh2kABAAAAAEAAAAaAAAAAAADoAEAAwAAAAEAAQAAoAIABAAAAAEAAAAgoAMABAAAAAEAAAAgAAAAAKyGYvMAAAGbaVRYdFhNTDpjb20uYWRvYmUueG1wAAAAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJYTVAgQ29yZSA2LjAuMCI+CiAgIDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgICAgIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiCiAgICAgICAgICAgIHhtbG5zOmV4aWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vZXhpZi8xLjAvIj4KICAgICAgICAgPGV4aWY6UGl4ZWxYRGltZW5zaW9uPjY0PC9leGlmOlBpeGVsWERpbWVuc2lvbj4KICAgICAgICAgPGV4aWY6UGl4ZWxZRGltZW5zaW9uPjY0PC9leGlmOlBpeGVsWURpbWVuc2lvbj4KICAgICAgPC9yZGY6RGVzY3JpcHRpb24+CiAgIDwvcmRmOlJERj4KPC94OnhtcG1ldGE+Cpt6TVoAAAXSSURBVFgJrVdNaF1FFD4z837SV7GIbTBFEEkragUhrYqoRTQUu3DRRV1IkaIgRSGKqy6zdeFCpG6kRdCKWjei0lSqoIJgW7W/IIXSYmkipjT9eWny7r0zx++be+9r8khfnz6HzJuZc2fO+eac8517Y6SPdveOS3tNtfGihpZYa8RYKLNWjDEYuc47BPncQc65cxi06YJ5qdKHfQkqk06hVFU0lJoUxmEHaz4SygkMYvGQO0w9Js7e5q1+xEf/vQXzU0jnYQQAChDKebn2+ZzP457yGUcfcMYs7wtAWk2/V58cV6nCABXmhkpj9Ew5JyiuFaDagOCJvgBMvz/YNGreUp822yAW3pLz6JncE20QhYyA+gLA2F3YvfI7yVrb1GcXxC5DkJFWMS/ihXFbbKLBstMTBbAAbzBN/pe28tXpobpWXkNyjRrx9yDNG2CEAxOq6PU2I8iMghWRKd2s3zF6ZoU0Kg8JWBP34XI5bRDzkj+YcmFtyJxxiVbsKmPCnfBEHRl/zpoKAh32g3oNsjOn4Q0QpZqov/PHLXPDXv03JriGGLjOGwnxBh5LaAPxjUe3AWsLpkHqkY3OBhpDwp0Nxo9ZYxKEoqHQEWsFWKigI8PTFcB8lp6vWjerxq6AaXC7SBmAAJJYbCK/CSbynbHO5/gFQF2H9QNIvpQbIijKcbSsE12TsLl/7TQOHyBOFg9VdNItdswpKztkgXOMpGQInKM8hWweB5sERhZ09q4ACDYL4R1N5y5pBAHlJYWYzZjHNQcajs8IEILYmTt6ESD/5LWXqhO3BNA8sPaU0fC6CTorpsa4RkOhMJIby4tQPs/BxNKMkIdWehm3/1oDQ5ODa3sBum4JgF6YmVjzaZDWFnD9V3AcagcQxDrCX8c4gJsho6IHiI23L0Bgbp2tVSput6RzpxVn4J58D72FecwVGumpjWvl9kPnRmFuo3FmEFlVMQ53s+4pWFrDzDLF2zDy3pEhsnnqw8GJoVf+xpnaZ9bV7hJJABx/rAf1kaPvcRC8KnEWUvzwjwvCI+1IGQodCGlNimmm1tacdS3v7C6nOmZry8dE53Ac+3mWTEGHDzZPfzw4QQ1DL09uMK7+tji30VWWoXggvfFW2iTVxn20Bd8SVkRG54C/uSLMqZjgtHjO/eIGxGRXVwJMs0xCiulaS+3Ux6FoU3tWH5Gtn29aveq5x3wy+yS8OAQAskts+i40IXaFwXgLMB9rE2U0DHXwUgRAN2NPYLyNLhfvr4nLKUZbdCKTlKVJFHoXtn0v+EmRnyFih+kkfCI+OaMKri/I7HamQlbeLn+V4lTM5px2SLgAUFOsB7h6ZMkNPdhzi2bl9IaLwLwTClJlOV0AIiqMAIrb0UAHlUIIVfDih+Dns5x6+d7yApIBWJcWI5QcH/lCQroDN7wmoFYOBO6m31nBOJZAIghSLQeDsTrTmPsF449iqu0LlOB9RwQ6sbRTJD35yB6cfkbD3F4N2RQS6Xr0SvApaixuV3gBY6k83hgBkH3rEoh3ataaiWW78FJ8P3Ra7Fi3AVCenhw5khxbvy0x8jBSaKMJYRQfks/C0HYk1Wz0RgmkDAcr4/i4vToxfBjhwBcyyq7BhwnCidASK9x387b02/D3kWm8vthjG3j02L1GFV6AUr6Wi2aswvNItPFccPXAmokVm/54Gpn4BgrJ8wC8CmTumgSLPFAq7hxho8ZKy+vEXnghfy8s3n3l2/vPXt4//Ka0wghC+ERw/tDiHYtXS3tg8R5ppdqsuZApPj4Et2ZxiY4oAY3jAPuCNnNw+AqWJxaIlpz25AHJqtPIhb8WsaHtBegdX1J3T8LeAJxal8D1XwqLFW9dJiJGxLsnQzfb1BsAnLY2+UD99UkJecVs0xIY+mk9A5g/+vg542VHCFn8J6QEED9M+kDQMwDaaJ1a/xVevVvEZ7/xs5YU5/94/bR/BYCG5k+MHEyqGSqm347KdxhJMStbH+xabLoB/AczyxKbTBtmRwAAAABJRU5ErkJggg==")

// MARK: - Jira key parsing

/// Parse a Jira issue key (e.g. "PROJ-123") from a Jira URL.
/// Prefers the component immediately after /browse/ or /issues/.
/// Falls back to any path component that matches the key pattern.
func parseJiraKey(from urlString: String) -> String? {
    guard let url = URL(string: urlString) else { return nil }
    let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

    // Priority: component adjacent to "browse" or "issues"
    for (i, component) in components.enumerated() {
        let lower = component.lowercased()
        if (lower == "browse" || lower == "issues") && i + 1 < components.count {
            let next = components[i + 1]
            if looksLikeJiraKey(next) { return next }
        }
    }

    // Fallback: any component matching the pattern
    return components.first(where: looksLikeJiraKey)
}

/// Returns true when `s` matches the Jira key pattern `[A-Z][A-Z0-9]+-[0-9]+`.
private func looksLikeJiraKey(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    // Must contain exactly one hyphen separating prefix and suffix.
    guard let hyphen = s.firstIndex(of: "-") else { return false }
    let prefix = String(s[s.startIndex..<hyphen])
    let suffix = String(s[s.index(after: hyphen)...])
    // prefix: starts with uppercase letter, rest uppercase letters or digits.
    guard let firstChar = prefix.first, firstChar.isUppercase else { return false }
    guard prefix.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return false }
    // suffix: one or more decimal digits only.
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return false }
    return true
}

// MARK: - JiraEntry

/// One attached Jira issue. Mirrors the GitHub widget's `PREntry` so the jira
/// widget supports MULTIPLE issues per session with the same storage shape
/// (`jira/issues` — a JSON array).
struct JiraEntry: Codable, Sendable, Equatable {
    var url: String
    var key: String?

    /// Decode `jira/issues` (`WidgetJSONValue.array`) into typed entries.
    static func decode(from value: WidgetJSONValue) -> [JiraEntry] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item -> JiraEntry? in
            guard case .object(let obj) = item,
                  case .string(let url) = obj["url"] else { return nil }
            let key: String?
            if case .string(let k) = obj["key"] { key = k } else { key = nil }
            return JiraEntry(url: url, key: key)
        }
    }

    /// Encode `[JiraEntry]` → `WidgetJSONValue.array`.
    static func encode(_ entries: [JiraEntry]) -> WidgetJSONValue {
        .array(entries.map { e in
            .object(["url": .string(e.url), "key": e.key.map { .string($0) } ?? .null])
        })
    }

    /// The stored issues, with a legacy single `jira/url` (+ `jira/key`) migrated
    /// into a one-element list when `jira/issues` is absent/empty — so a widget
    /// linked before multi-issue support keeps its issue.
    static func resolve(
        issues: WidgetJSONValue?,
        legacyURL: WidgetJSONValue?,
        legacyKey: WidgetJSONValue?
    ) -> [JiraEntry] {
        if let issues {
            let decoded = decode(from: issues)
            if !decoded.isEmpty { return decoded }
        }
        if case let .string(url)? = legacyURL, !url.isEmpty {
            let key: String?
            if case let .string(k)? = legacyKey, !k.isEmpty { key = k } else { key = parseJiraKey(from: url) }
            return [JiraEntry(url: url, key: key)]
        }
        return []
    }
}

// MARK: - JiraWidget

/// The Jira widget — pre-built, installed by default (feat/generalizations-of-features.6).
///
/// Widget id:  `jira`
/// Storage ns: reads and writes namespace `jira` (own namespace, since id == "jira").
///   jira/issues — JSON array of { url, key } (multiple issues, one tab each).
@Observable
@MainActor
final class JiraWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "jira"
    let title = "Jira"
    let icon = "ticket"
    var iconImageData: Data? { jiraMarkPNG }

    /// Session surfaces only — issues belong to a session, not the Home dashboard
    /// (the `jira-my-issues` board is the Home-facing widget). AC14.
    var enabledLayouts: Set<WidgetLayout> { Set(WidgetLayout.allCases).subtracting([.home]) }

    /// Jira Cloud pages are rendered by this widget. Receiving a URL only
    /// changes the in-memory BrowserSurface destination; attach remains an
    /// explicit storage-writing action.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [
                    .regex(JiraWidgetLinkSupport.cloudURLPattern),
                ],
                perform: { [weak self] url in
                    self?.openLink(url)
                }
            ),
        ]
    }

    // MARK: - Observed state

    /// The attached Jira issues (jira/issues storage). Empty = paste-URL form.
    var issues: [JiraEntry] = []
    /// A transient Open-Link destination, shown as a tab but not persisted as an
    /// attached issue (a link click is a viewing action, not attach).
    var openedLinkURL: URL? = nil
    /// Drives the attach-sheet presentation (the `+` in the browser chrome).
    var showingAttachForm: Bool = false
    /// Non-nil while storage is being read on first activate.
    var isLoading: Bool = false

    // MARK: - Internal (not observed)

    private var services: SessionServices?
    /// The `BrowserWidgetModel` stored from the `configure:` closure — for tab sync.
    var browserModel: BrowserWidgetModel?
    /// Stable UUID → URL mapping so tab close → detach works.
    private var tabIDs: [String: UUID] = [:]

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.loadAndSyncIssues()
        }
        // The live tab-reconcile subscription is driven by the view's `.task`
        // (see JiraWidgetMainView) so it runs only while the widget's tab is on
        // screen — with an immediate check on appear — not in the background.
    }

    func deactivate() {
        services = nil
        browserModel = nil
        openedLinkURL = nil
        isLoading = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(JiraWidgetMainView(widget: self, services: services))
    }

    // MARK: - Load from storage (with legacy migration)

    func loadAndSyncIssues() async {
        guard let services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let issuesVal = try await services.storage.get(namespace: "jira", key: "issues")
            let legacyURL = try? await services.storage.get(namespace: "jira", key: "url")
            let legacyKey = try? await services.storage.get(namespace: "jira", key: "key")
            let resolved = JiraEntry.resolve(issues: issuesVal, legacyURL: legacyURL ?? nil, legacyKey: legacyKey ?? nil)
            issues = resolved

            // Migrate a legacy single-issue layout into jira/issues, then drop
            // the legacy scalars so the array is the sole source of truth.
            let hadIssuesArray: Bool = {
                if case .array(let a)? = issuesVal { return !a.isEmpty }
                return false
            }()
            if !hadIssuesArray, !resolved.isEmpty {
                _ = await writeIssues(resolved)
                try? await services.storage.delete(key: "url")
                try? await services.storage.delete(key: "key")
            }
        } catch {
            // Storage unavailable (Home surface, no task) — stay in empty state.
            issues = []
        }
        syncTabs()
    }

    /// Re-read `jira/issues` and, when it changed out-of-band (an agent, the CLI,
    /// or `task42 storage set jira/issues`), append the new tab(s) and focus the
    /// newest — live, without a close/reopen. A no-op when the URL set is
    /// unchanged, so open tabs never thrash on the poll. Unlike
    /// `loadAndSyncIssues`, it skips legacy migration and the loading flag.
    func refreshFromStorage() async {
        guard let services else { return }
        let latest: [JiraEntry]
        do {
            let issuesVal = try await services.storage.get(namespace: "jira", key: "issues")
            let legacyURL = try? await services.storage.get(namespace: "jira", key: "url")
            let legacyKey = try? await services.storage.get(namespace: "jira", key: "key")
            latest = JiraEntry.resolve(issues: issuesVal, legacyURL: legacyURL ?? nil, legacyKey: legacyKey ?? nil)
        } catch {
            return  // storage briefly unavailable — keep the current tabs
        }
        let currentURLs = issues.map(\.url)
        let latestURLs = latest.map(\.url)
        guard currentURLs != latestURLs else { return }

        // Only auto-focus when appending to an EXISTING tab set. On first
        // population (empty → N, e.g. the immediate check on appear) let the tab
        // bar pick its default rather than hijacking selection to the last entry.
        let hadTabs = !currentURLs.isEmpty
        let addedURLs = latestURLs.filter { !currentURLs.contains($0) }
        issues = latest     // .onChange(displayedURLs) re-runs syncTabs()
        syncTabs()          // ensure the new tab exists before we select it
        if hadTabs, let newest = addedURLs.last {
            browserModel?.selectTab(stableTabID(for: newest))
        }
    }

    // MARK: - Tab sync

    /// Sync the BrowserSurface model's tab list from `displayedURLs` — one tab
    /// per attached issue (plus a transient opened-link tab).
    func syncTabs() {
        guard let model = BrowserSurface.model(forKey: id) else { return }
        let tabs: [BrowserTab] = displayedURLs.map { url in
            let urlString = url.absoluteString
            let label = keyForURL(urlString) ?? (url.host ?? urlString)
            return BrowserTab(id: stableTabID(for: urlString), url: url, title: label, icon: "ticket")
        }
        model.replaceTabs(tabs)
    }

    /// Attached issue URLs followed by the transient Open-Link destination, if
    /// it is not already attached.
    var displayedURLs: [URL] {
        var urls = issues.compactMap { URL(string: $0.url) }
        if let opened = openedLinkURL,
           !issues.contains(where: { $0.url == opened.absoluteString }) {
            urls.append(opened)
        }
        return urls
    }

    /// The parsed key for an attached URL (stored key first, else parse).
    private func keyForURL(_ urlString: String) -> String? {
        if let entry = issues.first(where: { $0.url == urlString }), let k = entry.key, !k.isEmpty {
            return k
        }
        return parseJiraKey(from: urlString)
    }

    /// Navigate to a Jira issue without attaching it — shows it as a tab.
    func openLink(_ url: URL) {
        openedLinkURL = url
        syncTabs()
        browserModel?.selectTab(stableTabID(for: url.absoluteString))
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

    /// Validate and attach a Jira issue URL. Returns an error string on failure,
    /// nil on success (or when already attached).
    func attach(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "URL cannot be empty." }
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            return "Not a valid URL. Expected https://your-org.atlassian.net/browse/PROJ-123."
        }
        guard !issues.contains(where: { $0.url == trimmed }) else { return nil }

        var updated = issues
        updated.append(JiraEntry(url: trimmed, key: parseJiraKey(from: trimmed)))
        return await writeIssues(updated)
    }

    // MARK: - Detach

    func detach(tabID: UUID) async {
        guard let urlString = urlForTabID(tabID) else { return }
        // A transient opened-link tab (not attached) → just drop it.
        if !issues.contains(where: { $0.url == urlString }) {
            if openedLinkURL?.absoluteString == urlString { openedLinkURL = nil }
            tabIDs.removeValue(forKey: urlString)
            syncTabs()
            return
        }
        let updated = issues.filter { $0.url != urlString }
        tabIDs.removeValue(forKey: urlString)
        _ = await writeIssues(updated)
    }

    // MARK: - Write issues to storage

    /// Persist the updated issue list to `jira/issues` and refresh `self.issues`.
    private func writeIssues(_ updated: [JiraEntry]) async -> String? {
        guard let services else { return "Widget not active." }
        do {
            try await services.storage.set(key: "issues", value: JiraEntry.encode(updated))
        } catch {
            return "Failed to write issue list: \(error.localizedDescription)"
        }
        issues = updated
        syncTabs()
        return nil
    }
}

// MARK: - Background agent (Work42WidgetBackground)

/// Publishes linked issue chip groups while the session is alive — regardless
/// of whether the widget's tab is shown. The key segment is unconditional;
/// Atlassian's `acli` enriches it with status and labels when available.
@Observable
@MainActor
final class JiraBackgroundAgent: WidgetBackgroundAgent {

    /// Session-scoped header chips. @Observable-backed so an update re-renders
    /// only the header strip.
    var headerLabels: [WidgetHeaderLabel] = []

    /// The running refresh loop. nil when stopped.
    private var watchTask: Task<Void, Never>?

    /// Guards the "acli isn't installed" system event so it's shelled at most
    /// once per session (the `task42 event` fingerprint also dedups at the DB
    /// level; this avoids re-shelling it every 60s poll).
    private var reportedMissingAcli = false

    func start(services: WidgetBackgroundServices) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh(services: services)
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        headerLabels = []
    }

    /// Re-read linked issues and publish key • status • label segments. Storage
    /// failures retain the prior labels; every CLI failure falls back to the
    /// newly-built key-only group without surfacing an error.
    private func refresh(services: WidgetBackgroundServices) async {
        let issuesVal: WidgetJSONValue?
        let legacyURL: WidgetJSONValue?
        let legacyKey: WidgetJSONValue?
        do {
            issuesVal = try await services.storage.get(namespace: "jira", key: "issues")
            legacyURL = try await services.storage.get(namespace: "jira", key: "url")
            legacyKey = try await services.storage.get(namespace: "jira", key: "key")
        } catch {
            return // storage unavailable — keep the last labels
        }

        let entries = JiraEntry.resolve(issues: issuesVal, legacyURL: legacyURL, legacyKey: legacyKey)

        // One segmented group per issue. The Jira-branded key always renders;
        // status/labels are appended only after a successful, parseable acli read.
        var labels: [WidgetHeaderLabel] = []
        for entry in entries {
            let key = entry.key ?? parseJiraKey(from: entry.url)
            let text = (key?.isEmpty == false) ? key! : (URL(string: entry.url)?.host ?? entry.url)
            let issueURL = URL(string: entry.url)
            labels.append(WidgetHeaderLabel(
                text: text,
                systemIcon: "ticket",
                iconImageData: jiraMarkPNG,
                brandColorHex: "#0052CC",   // Jira blue
                tint: .neutral,
                url: issueURL,
                groupId: entry.url
            ))

            guard let key, !key.isEmpty,
                  let state = await jiraState(for: key, services: services)
            else { continue }

            labels.append(WidgetHeaderLabel(
                text: state.status,
                tint: statusTint(state.status),
                url: issueURL,
                groupId: entry.url
            ))
            for label in state.labels {
                labels.append(WidgetHeaderLabel(
                    text: label,
                    systemIcon: "tag",
                    tint: .neutral,
                    url: issueURL,
                    groupId: entry.url
                ))
            }
        }
        headerLabels = labels
    }

    private func jiraState(
        for key: String,
        services: WidgetBackgroundServices
    ) async -> JiraCLIState? {
        let command = "\(jiraCLIPathPrefix) && acli jira workitem view \(key) "
            + "--fields status,labels --json"
        guard let result = try? await services.shell.run(command: command) else { return nil }
        // Exit 127 = command-not-found: `acli` isn't installed. Tell the session
        // once (fail-soft — chips stay key-only) so the agent can offer to set it
        // up. Other non-zero exits (e.g. not authenticated) are left silent here.
        if result.exitCode == 127 {
            await reportMissingAcliIfNeeded(services: services)
            return nil
        }
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return JiraCLIState(json: object)
    }

    /// Deliver a one-time `[system event]` telling the session `acli` is missing,
    /// with the install/auth steps. Guarded so it fires at most once per session.
    private func reportMissingAcliIfNeeded(services: WidgetBackgroundServices) async {
        guard !reportedMissingAcli else { return }
        reportedMissingAcli = true
        let message =
            "The Jira CLI (acli) isn't installed, so the Jira widget can't enrich "
            + "issue chips with status/labels or auto-name sessions from the issue "
            + "summary. Install it with: brew tap atlassian/homebrew-acli && brew "
            + "install acli, then authenticate: acli jira auth login --web. See the "
            + "using-jira-cli skill for details."
        await deliverEvent(services: services, message: message, fingerprint: "jira/acli-missing")
    }

    /// Post a `[system event]` into the current session via the task42/patrol42
    /// CLI (mirrors the github widget's delivery). The `if [ -n … ]` guard skips
    /// silently on Home/plain surfaces that have no task/patrol id.
    private func deliverEvent(
        services: WidgetBackgroundServices,
        message: String,
        fingerprint: String
    ) async {
        // Escape single quotes for safe sh single-quote embedding.
        let safeMsg = message.components(separatedBy: "'").joined(separator: "'\"'\"'")
        let safeFP = fingerprint.components(separatedBy: "'").joined(separator: "'\"'\"'")
        let cmd = """
            \(jiraCLIPathPrefix)
            if [ -n "$WORK42_TASK_ID" ]; then
              task42 event "$WORK42_TASK_ID" '\(safeMsg)' --fingerprint '\(safeFP)'
            elif [ -n "$WORK42_PATROL_ID" ]; then
              patrol42 event "$WORK42_PATROL_ID" '\(safeMsg)' --fingerprint '\(safeFP)'
            fi
            """
        _ = try? await services.shell.run(command: cmd)
    }

    private func statusTint(_ status: String) -> WidgetHeaderLabelTint {
        let normalized = status.lowercased()
        if normalized.contains("done") || normalized.contains("closed") || normalized.contains("resolved") {
            return .success
        }
        if normalized.contains("blocked") || normalized.contains("cancel") || normalized.contains("failed") {
            return .failure
        }
        if normalized.contains("progress") || normalized.contains("review") {
            return .warning
        }
        return .neutral
    }
}

private let jiraCLIPathPrefix =
    "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

private struct JiraCLIState {
    let status: String
    let labels: [String]

    init?(json: [String: Any]) {
        let fields = (json["fields"] as? [String: Any]) ?? json

        if let status = fields["status"] as? String {
            self.status = status
        } else if let statusObject = fields["status"] as? [String: Any],
                  let name = statusObject["name"] as? String,
                  !name.isEmpty {
            self.status = name
        } else {
            return nil
        }

        self.labels = (fields["labels"] as? [Any] ?? []).compactMap { value in
            guard let label = value as? String else { return nil }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// The host detects this conformance via `as? any Work42WidgetBackground` and
/// starts one agent per (session × widget) whenever the widget is available to
/// the session. Vendor knowledge (what a Jira key is) stays in the widget.
extension JiraWidget: Work42WidgetBackground {
    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        // Fresh instance per call — per-session isolation.
        JiraBackgroundAgent()
    }
}

// MARK: - JiraWidgetMainView

/// Root view dispatched from `makeView`. Shows the empty-state form when no issue
/// is attached, or the tabbed BrowserSurface otherwise.
@MainActor
private struct JiraWidgetMainView: View {
    let widget: JiraWidget
    let services: SessionServices

    var body: some View {
        Group {
            if widget.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if widget.displayedURLs.isEmpty {
                JiraEmptyStateView(widget: widget, services: services)
            } else {
                JiraBrowserView(widget: widget, services: services)
            }
        }
        // Live tab-reconcile, scoped to the view being on screen. `.task` runs
        // when the widget's tab is navigated to / first rendered and is cancelled
        // by SwiftUI when it leaves the screen — an immediate check on appear,
        // then subscribe (poll) for out-of-band `jira/issues` changes only while
        // visible. Runs in every state so a first external attach flips the empty
        // state to the browser live.
        .task {
            await widget.refreshFromStorage()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if Task.isCancelled { break }
                await widget.refreshFromStorage()
            }
        }
    }
}

// MARK: - JiraBrowserView

/// Renders the BrowserSurface with one tab per attached Jira issue. The chrome's
/// `+` opens an attach sheet; a tab's `×` detaches the issue.
@MainActor
private struct JiraBrowserView: View {
    let widget: JiraWidget
    let services: SessionServices

    private var firstURL: URL {
        widget.displayedURLs.first ?? URL(string: "https://www.atlassian.net")!
    }

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(
                url: firstURL,
                // No isolation selector: it blanks the whole page when the user
                // isn't signed in yet (nothing matches).
                selector: "",
                // Shared cookie store with the regular Browser widget.
                dataStoreKey: "browser",
                title: "Jira",
                icon: "ticket"
            ),
            cacheKey: widget.id,
            configure: { [weak widget] model in
                guard let widget else { return }
                widget.browserModel = model
                // Sync all issue tabs (replace the seeded first tab from spec).
                widget.syncTabs()
                // + opens the attach form.
                model.onNewTab = { [weak widget] in
                    widget?.showingAttachForm = true
                }
                // × detaches the issue.
                model.onTabClosed = { [weak widget] tabID in
                    Task { await widget?.detach(tabID: tabID) }
                }
            }
        )
        // Re-sync tabs when the issue list changes (out-of-band attach/detach).
        .onChange(of: widget.displayedURLs.map(\.absoluteString)) { _, _ in
            widget.syncTabs()
        }
        .sheet(isPresented: Binding(
            get: { widget.showingAttachForm },
            set: { widget.showingAttachForm = $0 }
        )) {
            JiraAttachSheet(widget: widget, services: services)
        }
    }
}

// MARK: - JiraEmptyStateView

/// Shown when no issue is attached. Paste a Jira URL to attach the first issue.
@MainActor
private struct JiraEmptyStateView: View {
    let widget: JiraWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var assigning = false

    var body: some View {
        VStack(spacing: DT.s16) {
            JiraBrandMark(size: 32)

            Text("No Jira ticket")
                .font(.system(size: DT.f13, weight: .medium))

            Text("Paste a Jira issue URL to embed it here. Add more later with the + in the tab bar. Sign in to Jira once and the session is kept.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://your-org.atlassian.net/browse/PROJ-123", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAttach)

                Button("Open in Work42", action: submitAttach)
                    .disabled(assigning || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
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
        guard !trimmed.isEmpty, !assigning else { return }
        assigning = true
        errorMessage = nil
        Task { @MainActor in
            defer { assigning = false }
            if let err = await widget.attach(urlString: trimmed) {
                errorMessage = err
            } else {
                draftURL = ""
            }
        }
    }
}

// MARK: - JiraAttachSheet

/// Modal sheet shown when the `+` button is pressed in the chrome row.
@MainActor
private struct JiraAttachSheet: View {
    let widget: JiraWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            JiraBrandMark(size: 28)

            Text("Attach a Jira issue")
                .font(.system(size: DT.f14, weight: .semibold))

            Text("Paste a Jira issue URL. A new tab is added and the issue is embedded.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://your-org.atlassian.net/browse/PROJ-123", text: $draftURL)
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

/// Reusable in-widget Jira identity mark. Browser tabs intentionally retain
/// their concise ticket glyph; the brand image identifies the widget itself.
private struct JiraBrandMark: View {
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let data = jiraMarkPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "ticket")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(DT.textTertiary)
        }
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
        result = WidgetEntryPoint.register(JiraWidget())
    }
    return result
}
