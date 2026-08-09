// Widget.swift — jira pre-built widget (feat/generalizations-of-features.6).
//
// Renders the Jira issue linked to the current task through a BrowserSurface.
// Two states, driven by whether the task has a Jira URL in storage:
//
//   EMPTY state   — paste-URL form. On submit, writes jira/url and jira/key
//                   into this widget's own storage namespace via services.storage
//                   (widget id "jira" == storage namespace "jira", so set(key:)
//                   writes to jira/<key> directly — no shell workaround needed).
//
//   ASSIGNED state — BrowserSurface with:
//                      selector:     "" (full page — an isolation selector
//                                     blanks the whole page when the user
//                                     isn't signed in yet, since nothing
//                                     matches; same bug class fixed on the
//                                     github widget's auth-gated selector)
//                      dataStoreKey: "browser" (cookies shared with the Browser widget)
//                      cacheKey:     id        (== "jira", enables chrome-as-header)
//                   A "Change ticket" overlay button clears storage and returns
//                   to the empty state.
//
// STORAGE CONVENTION (also documented in SKILL.md):
//   Read:  services.storage.get(namespace: "jira", key: "url")
//   Write: services.storage.set(key: "url", value: .string(urlString))
//          services.storage.set(key: "key", value: .string(issueKey))
//   Clear: services.storage.delete(key: "url")
//          services.storage.delete(key: "key")
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

// MARK: - PATH enrichment

/// Prepend common Homebrew / local dirs to PATH for the task42 shell invocations.
private let enrichedPathPrefix = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin\""

// MARK: - JiraWidget

/// The Jira widget — pre-built, installed by default (feat/generalizations-of-features.6).
///
/// Widget id:  `jira`
/// Storage ns: reads and writes namespace `jira` (own namespace, since id == "jira").
///   jira/url  — full Jira issue URL
///   jira/key  — parsed issue key (e.g. "PROJ-123")
@Observable
@MainActor
final class JiraWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "jira"
    let title = "Jira"
    let icon = "ticket"

    // MARK: - Observed state

    /// The Jira issue URL loaded from storage. nil = empty state (paste-URL form).
    var jiraURL: URL? = nil
    /// Non-nil while storage is being read on first activate.
    var isLoading: Bool = false

    // MARK: - Internal

    private var services: SessionServices?

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.loadStoredURL()
        }
    }

    func deactivate() {
        services = nil
        jiraURL = nil
        isLoading = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(JiraWidgetMainView(widget: self, services: services))
    }

    // MARK: - Load from storage

    func loadStoredURL() async {
        guard let services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let value = try await services.storage.get(namespace: "jira", key: "url"),
               case .string(let urlStr) = value,
               !urlStr.isEmpty,
               let url = URL(string: urlStr) {
                jiraURL = url
            } else {
                jiraURL = nil
            }
        } catch {
            // Storage unavailable (Home surface, no task) — stay in empty state.
            jiraURL = nil
        }
    }

    // MARK: - Assign (submit from empty-state form)

    /// Validate and persist a Jira URL. Returns an error string on failure, nil on success.
    func assign(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "URL cannot be empty." }
        guard let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http" else {
            return "Not a valid URL. Expected https://your-org.atlassian.net/browse/PROJ-123."
        }
        guard let services else { return "Widget is not active." }

        let key = parseJiraKey(from: trimmed)

        do {
            try await services.storage.set(key: "url", value: .string(trimmed))
            if let key {
                try await services.storage.set(key: "key", value: .string(key))
            }
        } catch {
            return "Failed to save Jira URL: \(error.localizedDescription)"
        }

        jiraURL = url
        return nil
    }

    // MARK: - Clear (return to empty state)

    /// Clear jira/url and jira/key from storage and return to the paste-URL form.
    func clear() async {
        guard let services else { return }
        do {
            try await services.storage.delete(key: "url")
            try await services.storage.delete(key: "key")
        } catch {
            // Fail silently on clear — the UI will still reset to empty state.
        }
        jiraURL = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }
}

// MARK: - JiraWidgetMainView

/// Root view dispatched from `makeView`. Shows the empty-state form when no URL
/// is stored, or the BrowserSurface when an issue is assigned.
@MainActor
private struct JiraWidgetMainView: View {
    let widget: JiraWidget
    let services: SessionServices

    var body: some View {
        if widget.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = widget.jiraURL {
            JiraBrowserView(widget: widget, services: services, url: url)
        } else {
            JiraEmptyStateView(widget: widget, services: services)
        }
    }
}

// MARK: - JiraBrowserView

/// Renders the BrowserSurface for the assigned Jira issue, with a
/// "Change ticket" overlay button to return to the empty state.
@MainActor
private struct JiraBrowserView: View {
    let widget: JiraWidget
    let services: SessionServices
    let url: URL

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BrowserSurface(
                spec: BrowserSurfaceSpec(
                    url: url,
                    // No isolation selector: it blanks the whole page when
                    // the user isn't signed in yet (nothing matches), same
                    // as the github widget's earlier auth-gated-selector bug.
                    selector: "",
                    // Shared cookie store with the regular Browser widget.
                    dataStoreKey: "browser",
                    title: "Jira",
                    icon: "ticket"
                ),
                cacheKey: widget.id
            )
            // "Change ticket" button — clears storage and returns to the paste-URL form.
            Button {
                Task { await widget.clear() }
            } label: {
                Label("Change ticket", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(DT.s8)
        }
    }
}

// MARK: - JiraEmptyStateView

/// Shown when no Jira issue is assigned. Provides a text field + button
/// to paste a Jira URL, which is parsed and written to storage on submit.
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

            Text("Paste a Jira issue URL to embed it here. Sign in to Jira once and the session is kept.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://your-org.atlassian.net/browse/PROJ-123", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAssign)

                Button("Open in Work42", action: submitAssign)
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

    private func submitAssign() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !assigning else { return }
        assigning = true
        errorMessage = nil
        Task { @MainActor in
            defer { assigning = false }
            if let err = await widget.assign(urlString: trimmed) {
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
        result = WidgetEntryPoint.register(JiraWidget())
    }
    return result
}
