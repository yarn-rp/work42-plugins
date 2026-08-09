// Widget.swift — jira-my-issues widget (feat/plugings-implementation.11).
//
// Lists the current user's assigned Jira issues via the Jira REST search API
// and renders one row per issue with a "Start work session" button.
//
// Three top-level states:
//
//   SETUP state   — a small form collecting jira/base, jira/email, jira/token.
//                   On submit the values are written into this widget's own
//                   storage namespace via services.storage.set (widget id
//                   "jira-my-issues" == storage namespace "jira-my-issues"):
//                     key "base"   → jira-my-issues/base
//                     key "email"  → jira-my-issues/email
//                     key "token"  → jira-my-issues/token
//
//   LOADED state  — one row per assigned issue (KEY + summary + status chip)
//                   plus a "Start work session" button per row. The button
//                   computes <base>/browse/<KEY> and fires:
//                     services.intents.execute(
//                       id: "global.new.task.jira",
//                       params: ["url": .string(issueURL)]
//                     )
//                   A "Reconfigure" button clears credentials and returns to
//                   the SETUP state. If the list is empty a clear "No assigned
//                   issues" message is shown (never a silent blank).
//
//   ERROR state   — a fail-loud card naming the problem and the remedy.
//                   Shown when: credentials are missing/invalid, the Jira API
//                   returns a non-parseable response, or the shell command
//                   fails. Never silently blank.
//
// STORAGE CONVENTION (also documented in SKILL.md):
//   Read:  services.storage.get(namespace: "jira-my-issues", key: "base")
//   Write: services.storage.set(key: "base",  value: .string(baseURL))
//          services.storage.set(key: "email", value: .string(email))
//          services.storage.set(key: "token", value: .string(apiToken))
//   Clear: services.storage.delete(key: "base")
//          services.storage.delete(key: "email")
//          services.storage.delete(key: "token")
//
// No background polling — fetch on activate + manual refresh only (v1).

import Foundation
import Observation
import SwiftUI
import Work42WidgetKit

// MARK: - JiraIssue model

/// One assigned Jira issue returned by the search endpoint.
struct JiraIssue: Identifiable {
    /// The Jira issue key (e.g. "PROJ-123"). Also used as `Identifiable.id`.
    let id: String
    let summary: String
    let statusName: String
}

// MARK: - JSON decoding helpers

private struct JiraSearchResponse: Decodable {
    let issues: [JiraIssueJSON]

    struct JiraIssueJSON: Decodable {
        let key: String
        let fields: Fields

        struct Fields: Decodable {
            let summary: String
            let status: StatusField

            struct StatusField: Decodable {
                let name: String
            }
        }
    }
}

private struct JiraErrorResponse: Decodable {
    let errorMessages: [String]
    let errors: [String: String]
}

/// Extract a human-readable error string from a Jira error response body.
private func extractJiraError(from data: Data) -> String? {
    guard let err = try? JSONDecoder().decode(JiraErrorResponse.self, from: data) else { return nil }
    if !err.errorMessages.isEmpty { return err.errorMessages.joined(separator: "; ") }
    if !err.errors.isEmpty { return err.errors.values.sorted().joined(separator: "; ") }
    return nil
}

// MARK: - Shell-quoting helper

/// Wrap `s` in single quotes, escaping any embedded single quotes so the
/// whole value can be safely spliced into a POSIX shell command line.
private func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - JiraMyIssuesWidget

/// The jira-my-issues widget — lists the user's assigned Jira issues and
/// provides one-click "Start work session" buttons per row.
///
/// Widget id:  `jira-my-issues`
/// Storage ns: `jira-my-issues` (own namespace)
@Observable
@MainActor
final class JiraMyIssuesWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "jira-my-issues"
    let title = "My Jira Issues"
    let icon = "list.bullet.clipboard"

    // MARK: - Widget state

    enum WidgetState {
        /// Credentials are absent or incomplete — show the setup form.
        case setup
        /// Fetching issues from the Jira API.
        case loading
        /// Issues loaded successfully (may be an empty array).
        case loaded([JiraIssue])
        /// A recoverable error: show the message and remedy.
        case error(message: String, remedy: String)
    }

    var widgetState: WidgetState = .setup

    // MARK: - Internal

    /// The base URL cached when credentials are successfully read. Used to
    /// build issue URLs for the intent without a second storage read.
    private(set) var cachedBase: String = ""

    private var services: SessionServices?

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.loadIssues()
        }
    }

    func deactivate() {
        services = nil
        widgetState = .setup
        cachedBase = ""
    }

    // MARK: - makeView

    func makeView(services: SessionServices) -> AnyView {
        AnyView(JiraMyIssuesMainView(widget: self, services: services))
    }

    // MARK: - Credential loading + issue fetching

    /// Read credentials from own storage namespace. If any are missing, show
    /// the setup form. If all present, fetch issues from the Jira API.
    func loadIssues() async {
        guard let services else { return }
        let ns = id   // "jira-my-issues"

        do {
            guard
                let baseVal = try await services.storage.get(namespace: ns, key: "base"),
                case .string(let base) = baseVal, !base.isEmpty,
                let emailVal = try await services.storage.get(namespace: ns, key: "email"),
                case .string(let email) = emailVal, !email.isEmpty,
                let tokenVal = try await services.storage.get(namespace: ns, key: "token"),
                case .string(let token) = tokenVal, !token.isEmpty
            else {
                // Credentials not configured — show the setup form.
                widgetState = .setup
                return
            }

            let normalizedBase = normalizeBaseURL(base)
            cachedBase = normalizedBase
            widgetState = .loading
            await fetchIssues(base: normalizedBase, email: email, token: token, services: services)

        } catch {
            // Storage unavailable (Home surface / no task) — stay in error state
            // and name the remedy rather than silently going to setup.
            widgetState = .error(
                message: "Storage is unavailable.",
                remedy: "Open this widget inside a task session to configure it."
            )
        }
    }

    /// Issue one curl request against the Jira REST search API and update
    /// `widgetState` with the result.
    private func fetchIssues(base: String, email: String, token: String, services: SessionServices) async {
        let jql = "assignee=currentUser()+AND+statusCategory!=Done&fields=summary,status&maxResults=50"
        let apiURL = "\(base)/rest/api/3/search?jql=\(jql)"
        let command =
            "curl -s --max-time 15 -u \(shellEscape("\(email):\(token)")) \(shellEscape(apiURL))"

        do {
            let result = try await services.shell.run(command: command)

            guard result.exitCode == 0 else {
                widgetState = .error(
                    message: "Jira API request failed (curl exit \(result.exitCode)).",
                    remedy: "Check the base URL is reachable and your network connection."
                )
                return
            }

            guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
                widgetState = .error(
                    message: "Empty response from Jira (\(base)).",
                    remedy: "Check the base URL is correct and the Jira site is accessible."
                )
                return
            }

            // Happy path: parse the search response.
            if let response = try? JSONDecoder().decode(JiraSearchResponse.self, from: data) {
                let issues = response.issues.map {
                    JiraIssue(id: $0.key, summary: $0.fields.summary, statusName: $0.fields.status.name)
                }
                widgetState = .loaded(issues)
                return
            }

            // Error path: try to surface a Jira-formatted error.
            let jiraErrorText = extractJiraError(from: data)
            let message = jiraErrorText ?? "Unexpected response from the Jira API."
            let lowerMessage = message.lowercased()
            let remedy: String
            if lowerMessage.contains("authentication")
                || lowerMessage.contains("unauthorized")
                || lowerMessage.contains("permission") {
                remedy = "Check your email and API token. "
                    + "Generate a new token at https://id.atlassian.com/manage-profile/security/api-tokens."
            } else {
                remedy = "Verify your Jira base URL, email, and API token. "
                    + "Use the Reconfigure button to update credentials."
            }
            widgetState = .error(message: message, remedy: remedy)

        } catch {
            widgetState = .error(
                message: "Shell command failed: \(error.localizedDescription)",
                remedy: "Ensure this widget is open inside a task session."
            )
        }
    }

    // MARK: - Credential management

    /// Validate `base`, `email`, `token`, persist them, and fetch issues.
    /// Returns an error string on validation/persistence failure, nil on success.
    func saveCredentials(base: String, email: String, token: String) async -> String? {
        guard let services else { return "Widget is not active." }

        let trimmedBase  = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBase.isEmpty  else { return "Base URL cannot be empty." }
        guard URL(string: trimmedBase) != nil else {
            return "Base URL is not a valid URL (expected https://myorg.atlassian.net)."
        }
        guard !trimmedEmail.isEmpty else { return "Email cannot be empty." }
        guard !trimmedToken.isEmpty else { return "API token cannot be empty." }

        do {
            try await services.storage.set(key: "base",  value: .string(trimmedBase))
            try await services.storage.set(key: "email", value: .string(trimmedEmail))
            try await services.storage.set(key: "token", value: .string(trimmedToken))
        } catch {
            return "Failed to save credentials: \(error.localizedDescription)"
        }

        let normalizedBase = normalizeBaseURL(trimmedBase)
        cachedBase = normalizedBase
        widgetState = .loading
        await fetchIssues(base: normalizedBase, email: trimmedEmail, token: trimmedToken, services: services)
        return nil
    }

    /// Clear all credentials from storage and return to the setup form.
    func resetCredentials() async {
        guard let services else { return }
        do {
            try await services.storage.delete(key: "base")
            try await services.storage.delete(key: "email")
            try await services.storage.delete(key: "token")
        } catch {
            // Fail silently on clear — the UI resets to setup state regardless.
        }
        cachedBase = ""
        widgetState = .setup
    }

    // MARK: - Session launch

    /// Fire the `global.new.task.jira` palette intent for `issueKey`.
    /// The intent opens (or re-focuses) a task session seeded with the issue URL.
    func startWorkSession(for issueKey: String) async {
        guard let services else { return }
        let issueURL = "\(cachedBase)/browse/\(issueKey)"
        do {
            try await services.intents.execute(
                id: "global.new.task.jira",
                params: ["url": .string(issueURL)]
            )
        } catch {
            // Intent failures are surfaced by the intent service itself.
            // A future revision may show an inline per-row error.
        }
    }

    // MARK: - Helpers

    /// Remove a trailing slash from `base` so URL building is consistent.
    private func normalizeBaseURL(_ base: String) -> String {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }
}

// MARK: - JiraMyIssuesMainView

/// Root view dispatched from `makeView`. Dispatches to the correct sub-view
/// based on `widget.widgetState`.
@MainActor
private struct JiraMyIssuesMainView: View {
    let widget: JiraMyIssuesWidget
    let services: SessionServices

    var body: some View {
        switch widget.widgetState {
        case .setup:
            JiraMyIssuesSetupView(widget: widget, services: services)
        case .loading:
            JiraMyIssuesLoadingView()
        case .loaded(let issues):
            JiraMyIssuesListView(widget: widget, services: services, issues: issues)
        case .error(let message, let remedy):
            JiraMyIssuesErrorView(
                widget: widget,
                services: services,
                message: message,
                remedy: remedy
            )
        }
    }
}

// MARK: - JiraMyIssuesSetupView

/// Shown when credentials are absent or incomplete. Collects jira/base,
/// jira/email, and jira/token and writes them to the widget's own storage.
@MainActor
private struct JiraMyIssuesSetupView: View {
    let widget: JiraMyIssuesWidget
    let services: SessionServices

    @State private var draftBase:  String = ""
    @State private var draftEmail: String = ""
    @State private var draftToken: String = ""
    @State private var errorMessage: String? = nil
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s24) {
                // Header
                HStack(spacing: DT.s12) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(DT.textTertiary)
                    VStack(alignment: .leading, spacing: DT.s4) {
                        Text("Configure Jira connection")
                            .font(.system(size: DT.f14, weight: .semibold))
                        Text("Enter your Atlassian site URL, account email, and API token.")
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Fields
                VStack(alignment: .leading, spacing: DT.s16) {
                    JiraSetupField(
                        label: "Site base URL",
                        placeholder: "https://myorg.atlassian.net",
                        hint: "The root URL of your Atlassian Cloud site (no trailing slash).",
                        text: $draftBase
                    )

                    JiraSetupField(
                        label: "Email",
                        placeholder: "you@example.com",
                        hint: "The email address of your Atlassian account.",
                        text: $draftEmail
                    )

                    JiraSetupField(
                        label: "API token",
                        placeholder: "ATATT3x...",
                        hint: "Generate at https://id.atlassian.com/manage-profile/security/api-tokens.\nNever a password — API tokens can be revoked independently.",
                        text: $draftToken,
                        isSecure: true
                    )
                }

                // Error message
                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(DT.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Submit
                HStack {
                    Spacer()
                    Button("Save & Fetch Issues", action: submit)
                        .disabled(saving || anyFieldEmpty)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
            .padding(DT.s24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var anyFieldEmpty: Bool {
        draftBase.trimmingCharacters(in: .whitespaces).isEmpty
        || draftEmail.trimmingCharacters(in: .whitespaces).isEmpty
        || draftToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard !saving, !anyFieldEmpty else { return }
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            if let err = await widget.saveCredentials(
                base: draftBase, email: draftEmail, token: draftToken
            ) {
                errorMessage = err
            }
        }
    }
}

// MARK: - JiraSetupField

/// A labeled text-field row used inside the setup form.
@MainActor
private struct JiraSetupField: View {
    let label: String
    let placeholder: String
    let hint: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s4) {
            Text(label)
                .font(.system(size: DT.f12, weight: .medium))
            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: DT.f12))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: DT.f12))
            }
            Text(hint)
                .font(.system(size: DT.f10))
                .foregroundStyle(DT.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - JiraMyIssuesLoadingView

/// Shown while the Jira API request is in flight.
@MainActor
private struct JiraMyIssuesLoadingView: View {
    var body: some View {
        VStack(spacing: DT.s12) {
            ProgressView()
            Text("Fetching assigned issues…")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - JiraMyIssuesListView

/// Shown when issues are loaded. One row per issue, each with a
/// "Start work session" button. Empty list gets an explicit message.
@MainActor
private struct JiraMyIssuesListView: View {
    let widget: JiraMyIssuesWidget
    let services: SessionServices
    let issues: [JiraIssue]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar row
            HStack {
                Text("Assigned issues")
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(DT.textSecondary)
                Spacer()
                Button {
                    Task { await widget.loadIssues() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: DT.f11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await widget.resetCredentials() }
                } label: {
                    Label("Reconfigure", systemImage: "gear")
                        .font(.system(size: DT.f11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, DT.s16)
            .padding(.vertical, DT.s8)

            Divider()

            if issues.isEmpty {
                // Explicit empty state — never a silent blank
                VStack(spacing: DT.s12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(DT.textTertiary)
                    Text("No assigned issues")
                        .font(.system(size: DT.f13, weight: .medium))
                    Text("No issues assigned to you with a non-Done status were found.")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(issues) { issue in
                            JiraIssueRow(widget: widget, services: services, issue: issue)
                            Divider()
                                .padding(.leading, DT.s16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - JiraIssueRow

/// One issue row: KEY + summary + status chip + "Start work session" button.
@MainActor
private struct JiraIssueRow: View {
    let widget: JiraMyIssuesWidget
    let services: SessionServices
    let issue: JiraIssue

    @State private var launching = false

    var body: some View {
        HStack(alignment: .center, spacing: DT.s12) {
            // Left: key + summary
            VStack(alignment: .leading, spacing: DT.s4) {
                HStack(spacing: DT.s8) {
                    Text(issue.id)
                        .font(.system(size: DT.f11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DT.systemAccent)
                    StatusChip(statusName: issue.statusName)
                }
                Text(issue.summary)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(DT.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: action button
            Button {
                launching = true
                Task { @MainActor in
                    defer { launching = false }
                    await widget.startWorkSession(for: issue.id)
                }
            } label: {
                Label(
                    launching ? "Opening…" : "Start work session",
                    systemImage: launching ? "hourglass" : "play.circle"
                )
                .font(.system(size: DT.f11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(launching)
        }
        .padding(.horizontal, DT.s16)
        .padding(.vertical, DT.s12)
    }
}

// MARK: - StatusChip

/// A small pill showing the issue's status name.
@MainActor
private struct StatusChip: View {
    let statusName: String

    var body: some View {
        Text(statusName)
            .font(.system(size: DT.f10, weight: .medium))
            .foregroundStyle(DT.textSecondary)
            .padding(.vertical, DT.chipPadV)
            .padding(.horizontal, DT.chipPadH)
            .background(DT.chipFill)
            .overlay(
                RoundedRectangle(cornerRadius: DT.rPill)
                    .stroke(DT.chipStroke, lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

// MARK: - JiraMyIssuesErrorView

/// A fail-loud error card naming the problem and the remedy. Never a silent
/// blank. Provides a "Retry" button and a "Reconfigure" button.
@MainActor
private struct JiraMyIssuesErrorView: View {
    let widget: JiraMyIssuesWidget
    let services: SessionServices
    let message: String
    let remedy: String

    var body: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.amber)

            Text("Could not load Jira issues")
                .font(.system(size: DT.f13, weight: .semibold))

            VStack(spacing: DT.s8) {
                Text(message)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(DT.red)
                    .multilineTextAlignment(.center)

                Text(remedy)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 380)

            HStack(spacing: DT.s8) {
                Button("Retry") {
                    Task { await widget.loadIssues() }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Reconfigure") {
                    Task { await widget.resetCredentials() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        result = WidgetEntryPoint.register(JiraMyIssuesWidget())
    }
    return result
}
