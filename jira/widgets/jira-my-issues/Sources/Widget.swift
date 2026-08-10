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
//                   A "Change board" overlay button clears storage and returns
//                   to the empty state. The configure: closure stashes the
//                   BrowserWidgetModel so the action-area intent can read the
//                   current URL.
//
// ACTION-AREA INTENT: "start-task-session"
//   placement:       [.actionArea, .palette]
//   actionAreaStyle: .labeled
//   isEnabled:       true only when model.urlDraft contains "/browse/" (i.e.
//                    the browser is on a Jira issue page, e.g. /browse/PROJ-123)
//   perform:         services.intents.execute(
//                      id: "global.new.task",
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

import Observation
import SwiftUI
import Work42WidgetKit

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

    // MARK: - Observed state

    /// The board URL loaded from storage. nil = empty state (paste-URL form).
    var boardURL: URL? = nil

    /// True while storage is being read on first activate (prevents flashing
    /// the empty-state form before the stored URL loads).
    var isLoading: Bool = false

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
                    // Enabled only when the browser is on a Jira issue page.
                    return urlDraft.contains("/browse/")
                },
                perform: { [weak self] in
                    guard let self else { return }
                    let model = self.browserModel ?? BrowserSurface.model(forKey: self.id)
                    let currentURL = model?.urlDraft ?? ""
                    guard !currentURL.isEmpty else { return }
                    guard let services = self.services else { return }
                    try await services.intents.execute(
                        id: "global.new.task",
                        params: ["url": .string(currentURL)]
                    )
                }
            )
        ]
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

/// Renders the BrowserSurface for the pinned Jira board URL, with a
/// "Change board" overlay button to return to the paste-URL form.
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

            // "Change board" button — clears the stored URL and returns to the
            // paste-URL form. Stays bottom-trailing so it doesn't obscure the
            // board content.
            Button {
                Task { await widget.clearBoardURL() }
            } label: {
                Label("Change board", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(DT.s8)
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
            Image(systemName: "ticket")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.textTertiary)

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
