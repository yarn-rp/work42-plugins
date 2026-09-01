// Widget.swift — jira-my-issues widget (feat/plugings-implementation.16).
//
// Reworked from a REST/credential-form list widget to a Home-surface browser
// widget that pins the user's Jira board URL via a BrowserSurface.
//
// Two states, driven by whether a board URL is stored:
//
//   EMPTY state   — paste-URL form. On submit writes:
//                     services.storage.set(key: "board", value: .string(boardURL))
//                   into this widget's own namespace ("jira-my-issues").
//                   The URL is stored ONCE; the form does NOT reappear on
//                   subsequent activations (unless the user changes it).
//
//   BOARD state   — BrowserSurface with:
//                     source:       .url(boardURL)
//                     selector:     "" (full page)
//                     dataStoreKey: "browser" (shared cookie store with the
//                                   regular Browser widget — sign in once)
//                     title:        "Jira"
//                     cacheKey:     id ("jira-my-issues")
//                   An "Edit board" overlay opens a pre-filled editor. Saving
//                   replaces the stored URL in place; removing it is a separate
//                   destructive action. The configure: closure stashes the
//                   BrowserWidgetModel so the action-area intent can read the
//                   current URL.
//
// ACTION-AREA INTENT: "start-task-session"
//   placement:       [.actionArea, .palette]
//   actionAreaStyle: .labeled
//   isEnabled:       true whenever model.urlDraft names a Jira issue — a
//                    /browse/<KEY> page, an issue open in a board/backlog/nav
//                    modal (selectedIssue=<KEY>), a next-gen /issues/<KEY>, or a
//                    JSM queue item. See jiraIssueKey(from:).
//   perform:         services.intents.execute(
//                      id: "global.new.task.jira",
//                      params: ["url": .string(currentURL)]
//                    )
//
// STORAGE CONVENTION (also documented in SKILL.md):
//   Read:  services.storage.get(namespace: "jira-my-issues", key: "board")
//   Write: services.storage.set(key: "board", value: .string(boardURL))
//   Clear: services.storage.delete(key: "board")
//
//   On the Home surface storage is backed by ProjectStorageBackend (per-project
//   file at ~/.work42/task42/projects/<slug>/home-widget-storage.json).
//   On a task session, storage is backed by task_storage (per-task).
//
// NO API token, NO email/credential form — authentication is through the shared
// browser login. Sign in to Jira once via the BrowserSurface; the cookie store
// (dataStoreKey "browser") persists across sessions.

import AppKit
import Observation
import SwiftUI
import Work42WidgetKit

private let jiraMarkPNG = Data(base64Encoded: "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")

// MARK: - Jira issue-key extraction

/// True when `s` (already uppercased) looks like a Jira issue key: a project key
/// (a letter, then letters/digits) + "-" + a number — e.g. `PROJ-123`, `AB2-7`.
private func isJiraIssueKey(_ s: String) -> Bool {
    guard let dash = s.firstIndex(of: "-") else { return false }
    let project = s[s.startIndex..<dash]
    let number = s[s.index(after: dash)...]
    guard let first = project.first, first.isLetter else { return false }
    guard project.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
    guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return false }
    return true
}

/// Extract a Jira issue key from any of Jira's issue-URL shapes:
///
///   • Direct issue:                …/browse/PROJ-123
///   • Board / backlog / sprint / planning modal, classic RapidBoard, and the
///     issue navigator — the open issue rides in the query string:
///                                  …/boards/1?selectedIssue=PROJ-123
///   • Team-managed (next-gen) issue view — key in the path:
///                                  …/jira/software/projects/PROJ/issues/PROJ-123
///   • Jira Service Management queue item — key as the last path segment:
///                                  …/servicedesk/projects/ABC/queues/custom/1/ABC-123
///
/// Precedence: the `selectedIssue` query param wins (the most specific
/// "currently open" marker), then `/browse/<KEY>`, then the last key-shaped
/// path segment. Returns the uppercased key, or nil when the URL names no issue.
private func jiraIssueKey(from urlString: String) -> String? {
    guard let comps = URLComponents(string: urlString) else { return nil }

    // 1. Query string — `selectedIssue` is Jira's canonical marker for an issue
    //    open in a modal/panel over a board, backlog, sprint, or the navigator.
    if let items = comps.queryItems {
        for name in ["selectedIssue", "issueKey", "issue"] {
            if let value = items.first(where: { $0.name == name })?.value?.uppercased(),
               isJiraIssueKey(value) {
                return value
            }
        }
    }

    let segments = comps.path.split(separator: "/").map { $0.uppercased() }

    // 2. /browse/<KEY> — the canonical direct issue page.
    if let idx = segments.firstIndex(of: "BROWSE"), idx + 1 < segments.count,
       isJiraIssueKey(segments[idx + 1]) {
        return segments[idx + 1]
    }

    // 3. Otherwise the last key-shaped path segment (next-gen /issues/<KEY>,
    //    a JSM queue item, etc.).
    return segments.last(where: isJiraIssueKey)
}

/// The canonical direct-issue URL (`https://<host>/browse/<KEY>`) used to seed
/// the opened session, so its Jira browser loads the ISSUE itself — not the
/// board/backlog the modal was opened over. Falls back to `original` when the
/// host can't be resolved.
private func canonicalJiraIssueURL(key: String, from original: String) -> String {
    guard let comps = URLComponents(string: original),
          let scheme = comps.scheme, let host = comps.host else { return original }
    var base = "\(scheme)://\(host)"
    if let port = comps.port { base += ":\(port)" }
    return base + "/browse/\(key)"
}

// MARK: - JiraBoardWidget

/// The jira-my-issues widget (reworked to a Home-surface Jira board browser).
///
/// Widget id:  `jira-my-issues`
/// Storage ns: `jira-my-issues` (own namespace)
///   jira-my-issues/board — string, the pinned Jira board URL.
@Observable
@MainActor
final class JiraBoardWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "jira-my-issues"
    let title = "Jira Board"
    let icon = "ticket"
    var iconImageData: Data? { jiraMarkPNG }

    /// Home-only board, matching `github-prs` — the personal Jira dashboard
    /// belongs on Home, not inside a session. AC14.
    var enabledLayouts: Set<WidgetLayout> { [.home] }

    /// This dashboard starts task sessions but is not a link destination.
    let linkIntents: [WidgetLinkIntentSpec] = []

    // MARK: - Observed state

    /// The board URL loaded from storage. nil = empty state (paste-URL form).
    var boardURL: URL? = nil

    /// True while storage is being read on first activate (prevents flashing
    /// the empty-state form before the stored URL loads).
    var isLoading: Bool = false

    /// Drives the edit sheet for an already-pinned board.
    var showingBoardEditor: Bool = false

    // MARK: - Internal

    private var services: SessionServices?

    /// Stashed reference to the BrowserWidgetModel, set once in the configure:
    /// closure when the BrowserSurface becomes live.
    /// @ObservationIgnored: changes to this field do not need to trigger SwiftUI
    /// observations — the model itself is @Observable and its urlDraft is tracked
    /// directly by any closure that reads it.
    /// fileprivate so the configure: closure inside JiraBoardBrowserView (same
    /// source file, different type) can write the model reference without
    /// crossing the private boundary.
    @ObservationIgnored
    fileprivate var browserModel: BrowserWidgetModel?

    // MARK: - Intents

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "start-task-session",
                title: "Start Task Session",
                icon: "play.circle",
                iconImageData: jiraMarkPNG,
                brandColorHex: "#0052CC",
                keywords: ["jira", "task", "session", "start", "issue", "browse"],
                placement: [.actionArea, .palette],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    // Prefer the stashed model; fall back to the static cache
                    // accessor in case configure hasn't fired yet.
                    let urlDraft = self.browserModel?.urlDraft
                        ?? BrowserSurface.model(forKey: self.id)?.urlDraft
                        ?? ""
                    // Enabled whenever the browser names a Jira issue — a
                    // /browse/ page OR an issue open in a board/backlog/nav modal
                    // (selectedIssue=…), a next-gen /issues/<KEY>, or a JSM queue
                    // item. See jiraIssueKey(from:).
                    return jiraIssueKey(from: urlDraft) != nil
                },
                perform: { [weak self] in
                    guard let self else { return }
                    let model = self.browserModel ?? BrowserSurface.model(forKey: self.id)
                    let currentURL = model?.urlDraft ?? ""
                    guard !currentURL.isEmpty else { return }
                    guard let services = self.services else { return }
                    // Resolve the key from whichever shape the URL uses (path or
                    // a modal's selectedIssue query param), then seed the session
                    // with the CANONICAL /browse/<KEY> URL so its Jira browser
                    // opens the issue itself — not the board/backlog the modal
                    // was opened over. The typed session intent creates the task,
                    // seeds jira/url so the issue loads immediately, and owns the
                    // loading/error overlay.
                    let issueKey = jiraIssueKey(from: currentURL)
                    let seededURL = issueKey
                        .map { canonicalJiraIssueURL(key: $0, from: currentURL) } ?? currentURL
                    // Name the session "<KEY>: <summary>". The summary is a
                    // fail-soft `acli` lookup (a nicer name when acli answers,
                    // the bare key when it doesn't) — mirrors the github-prs
                    // `gh`-title path; never blocks launch.
                    let taskName: String
                    if let key = issueKey, !key.isEmpty {
                        taskName = await Self.sessionName(forKey: key, services: services)
                    } else {
                        taskName = "Jira Task"
                    }
                    try await services.intents.execute(
                        id: "session.open.task",
                        params: [
                            "kind": .string("task"),
                            "task": .object([
                                "name": .string(taskName),
                                "kind": .string("feature"),
                            ]),
                            "initialWidgetStorage": .object([
                                "jira": .object([
                                    "url": .string(seededURL),
                                ]),
                            ]),
                        ]
                    )
                }
            )
        ]
    }

    /// The session name for a linked issue: `"<KEY>: <summary>"` when a
    /// fail-soft `acli` lookup answers, else the bare key. Mirrors the
    /// github-prs `gh`-title path — a nicer name when the CLI is available,
    /// never blocking or failing the launch.
    private static func sessionName(forKey key: String, services: SessionServices) async -> String {
        let command = "\(jiraCLIPathPrefix) && acli jira workitem view \(key) "
            + "--fields summary --json"
        guard let result = try? await services.shell.run(command: command),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return key }
        let fields = (object["fields"] as? [String: Any]) ?? object
        let summary = (fields["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? key : "\(key): \(summary)"
    }

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.loadBoardURL()
        }
    }

    func deactivate() {
        services = nil
        boardURL = nil
        browserModel = nil
        showingBoardEditor = false
        isLoading = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(JiraBoardWidgetMainView(widget: self, services: services))
    }

    // MARK: - Storage

    /// Read the board URL from own storage namespace. If absent or unavailable,
    /// leave boardURL as nil so the paste-URL form is shown.
    func loadBoardURL() async {
        guard let services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let value = try await services.storage.get(namespace: "jira-my-issues", key: "board"),
               case .string(let urlStr) = value,
               !urlStr.isEmpty,
               let url = URL(string: urlStr) {
                boardURL = url
            } else {
                boardURL = nil
            }
        } catch {
            // Storage unavailable (no task or home-storage not yet configured) —
            // show the paste-URL form rather than a silent blank or an error card.
            boardURL = nil
        }
    }

    /// Validate and persist a board URL. Returns an error string on failure,
    /// nil on success.
    func saveBoardURL(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Board URL cannot be empty." }
        guard let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http" else {
            return "Not a valid URL. Expected https://your-org.atlassian.net/..."
        }
        guard let services else { return "Widget is not active." }

        do {
            try await services.storage.set(key: "board", value: .string(trimmed))
        } catch {
            return "Failed to save board URL: \(error.localizedDescription)"
        }

        if boardURL != url {
            browserModel = nil
            BrowserSurfaceCache.shared.teardown(key: id)
        }
        boardURL = url
        return nil
    }

    /// Clear the board URL from storage and return to the paste-URL form.
    func clearBoardURL() async {
        guard let services else { return }
        do {
            try await services.storage.delete(key: "board")
        } catch {
            // Fail silently on clear — the UI resets to empty state regardless.
        }
        boardURL = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }
}

// MARK: - JiraBoardWidgetMainView

/// Root view dispatched from makeView. Dispatches to the correct sub-view
/// based on widget.boardURL.
@MainActor
private struct JiraBoardWidgetMainView: View {
    let widget: JiraBoardWidget
    let services: SessionServices

    var body: some View {
        if widget.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = widget.boardURL {
            JiraBoardBrowserView(widget: widget, url: url)
        } else {
            JiraBoardEmptyStateView(widget: widget)
        }
    }
}

// MARK: - JiraBoardBrowserView

/// Renders the BrowserSurface for the pinned Jira board URL, with an
/// "Edit board" overlay that opens a pre-filled editor.
/// The configure: closure stashes the BrowserWidgetModel on the widget
/// so the "Start Task Session" intent can read the current page URL.
@MainActor
private struct JiraBoardBrowserView: View {
    let widget: JiraBoardWidget
    let url: URL

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BrowserSurface(
                spec: BrowserSurfaceSpec(
                    url: url,
                    // No isolation selector: show the full Jira board page.
                    // An auth-gated selector would blank the page for logged-out
                    // users; an empty selector works from the first load.
                    selector: "",
                    // Shared cookie store with the Browser and Jira widgets —
                    // sign in once, stay signed in across widgets.
                    dataStoreKey: "browser",
                    title: "Jira",
                    icon: "ticket"
                ),
                cacheKey: widget.id,
                configure: { [weak widget] model in
                    // Stash the model so the action-area intent can read the
                    // current browser URL (model.urlDraft) without going through
                    // the cache every time.
                    widget?.browserModel = model
                }
            )

            // Editing no longer clears first: the current URL is seeded into a
            // sheet and replaced only after validation succeeds.
            Button {
                widget.showingBoardEditor = true
            } label: {
                Label("Edit board", systemImage: "pencil")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(DT.s8)
        }
        .sheet(isPresented: Binding(
            get: { widget.showingBoardEditor },
            set: { widget.showingBoardEditor = $0 }
        )) {
            JiraBoardEditSheet(widget: widget, currentURL: url)
        }
    }
}

// MARK: - JiraBoardEditSheet

/// Edits an existing board without clearing the stored value first. The prior
/// URL remains active when validation or persistence fails.
@MainActor
private struct JiraBoardEditSheet: View {
    let widget: JiraBoardWidget

    @State private var draftURL: String
    @State private var errorMessage: String? = nil
    @State private var saving = false

    init(widget: JiraBoardWidget, currentURL: URL) {
        self.widget = widget
        _draftURL = State(initialValue: currentURL.absoluteString)
    }

    var body: some View {
        VStack(spacing: DT.s16) {
            JiraBrandMark(size: 28)

            Text("Edit Jira board")
                .font(.system(size: DT.f14, weight: .semibold))

            TextField(
                "https://your-org.atlassian.net/jira/software/projects/PROJ/boards",
                text: $draftURL
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveBoard)
            .frame(width: 460)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: DT.s8) {
                Button("Remove board", role: .destructive) {
                    Task { @MainActor in
                        await widget.clearBoardURL()
                        widget.showingBoardEditor = false
                    }
                }

                Spacer()

                Button("Cancel") {
                    widget.showingBoardEditor = false
                }

                Button("Save board", action: saveBoard)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DT.s24)
        .frame(minWidth: 520)
    }

    private func saveBoard() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            if let error = await widget.saveBoardURL(urlString: trimmed) {
                errorMessage = error
            } else {
                widget.showingBoardEditor = false
            }
        }
    }
}

// MARK: - JiraBoardEmptyStateView

/// Shown when no board URL is stored. Provides a text field + button
/// to paste a Jira board URL, written to storage on submit.
/// After a successful submit the widget transitions to BOARD state without
/// requiring another activation — saveBoardURL sets boardURL directly.
@MainActor
private struct JiraBoardEmptyStateView: View {
    let widget: JiraBoardWidget

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var saving = false

    var body: some View {
        VStack(spacing: DT.s16) {
            JiraBrandMark(size: 32)

            Text("No Jira board pinned")
                .font(.system(size: DT.f13, weight: .medium))

            Text("Paste your Jira board URL to pin it here. Sign in to Jira once and the browser session is kept across restarts.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            HStack(spacing: DT.s8) {
                TextField(
                    "https://your-org.atlassian.net/jira/software/projects/PROJ/boards",
                    text: $draftURL
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitBoard)

                Button("Pin board", action: submitBoard)
                    .disabled(saving || draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 480)

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitBoard() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            if let err = await widget.saveBoardURL(urlString: trimmed) {
                errorMessage = err
            } else {
                draftURL = ""
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
        result = WidgetEntryPoint.register(JiraBoardWidget())
    }
    return result
}

// PATH enrichment for the fail-soft `acli` session-name lookup. The app may be
// launched from Finder with a minimal PATH that omits Homebrew/local dirs.
private let jiraCLIPathPrefix =
    "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""
