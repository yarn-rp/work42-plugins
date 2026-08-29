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

import Observation
import SwiftUI
import Work42WidgetKit

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

/// Publishes the linked issue's key chip(s) to the session header while the
/// session is alive — regardless of whether the widget's tab is shown — mirroring
/// the GitHub PR widget's agent-based labels. The Jira widget has no headless
/// data source (it renders a Jira page via a cookie-auth BrowserSurface), so the
/// "background process" only re-reads the linked issues from storage and
/// republishes the chip(s); it never fetches Jira state.
@Observable
@MainActor
final class JiraBackgroundAgent: WidgetBackgroundAgent {

    /// Session-scoped header chips. @Observable-backed so an update re-renders
    /// only the header strip.
    var headerLabels: [WidgetHeaderLabel] = []

    /// The running refresh loop. nil when stopped.
    private var watchTask: Task<Void, Never>?

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

    /// Re-read the linked issues from the widget's own `jira` storage namespace
    /// and publish the issue-key chip(s). Read-only; fails quietly when storage
    /// is unavailable, and clears when no issue is linked.
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
        guard let first = entries.first else {
            headerLabels = []
            return
        }
        let key = first.key ?? parseJiraKey(from: first.url)
        guard let key, !key.isEmpty else {
            headerLabels = []
            return
        }
        headerLabels = [WidgetHeaderLabel(
            text: key, systemIcon: "ticket",
            tint: .accent, url: URL(string: first.url)
        )]
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
        if widget.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if widget.displayedURLs.isEmpty {
            JiraEmptyStateView(widget: widget, services: services)
        } else {
            JiraBrowserView(widget: widget, services: services)
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
            Image(systemName: "ticket")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.textTertiary)

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
