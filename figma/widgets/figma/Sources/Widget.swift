// Widget.swift — figma pre-built widget (figma-plugin-mcp-registry-and-usage.10).
//
// Renders the Figma file(s) attached to the current session through a
// BrowserSurface with ONE TAB PER LINK — mirroring the Jira/GitHub widgets.
// Two states, driven by whether any link is stored:
//
//   EMPTY state    — paste-URL form. On submit, appends the file to figma/links.
//
//   ATTACHED state — BrowserSurface with one tab per attached file:
//                      selector:     "" (full page — an isolation selector
//                                     blanks the whole page when the user isn't
//                                     signed in yet, since nothing matches)
//                      dataStoreKey: "browser" (cookies shared with the Browser widget)
//                      cacheKey:     id ("figma")
//                    The chrome's `+` opens an attach sheet; a tab's `×` detaches.
//
// STORAGE (widget id "figma" == namespace "figma"):
//   figma/links — JSON array of { url, name } (the source of truth). The
//   `using-figma` skill reads THIS namespace to know which files are attached,
//   then queries the Figma MCP (mcp__figma__*) for design data.
//
// The Figma MCP itself is declared in plugin.yaml (http https://mcp.figma.com/mcp,
// bridged via mcp-remote) and injected by the work42 registry — the widget does
// NOT do any Figma auth; the first MCP call triggers mcp-remote's browser OAuth.

import AppKit
import Observation
import SwiftUI
import Work42WidgetKit

// MARK: - Figma URL helpers

/// A human label for a Figma file URL. Figma file/design URLs look like
/// `https://www.figma.com/design/<key>/<Name>?...` — the name is the component
/// after the key. Falls back to the host.
func figmaDisplayName(from urlString: String) -> String? {
    guard let url = URL(string: urlString) else { return nil }
    let comps = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    for (i, c) in comps.enumerated() {
        let lower = c.lowercased()
        if (lower == "file" || lower == "design" || lower == "board" || lower == "proto"),
           i + 2 < comps.count {
            return comps[i + 2].replacingOccurrences(of: "-", with: " ")
        }
    }
    return url.host
}

/// True when `urlString` is a figma.com URL (any subdomain).
func isFigmaURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return false }
    return host == "figma.com" || host.hasSuffix(".figma.com")
}

/// Regex matching a Figma file/design/board/proto URL, for the widget's
/// link-intent (a pasted/opened Figma link routes to this widget).
let figmaURLPattern = #"^https?://([a-z0-9-]+\.)?figma\.com/(file|design|board|proto)/"#

// MARK: - FigmaLink

/// One attached Figma file. Stored as a JSON array at `figma/links`.
struct FigmaLink: Codable, Sendable, Equatable {
    var url: String
    var name: String?

    /// Decode `figma/links` (`WidgetJSONValue.array`) into typed entries.
    static func decode(from value: WidgetJSONValue) -> [FigmaLink] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item -> FigmaLink? in
            guard case .object(let obj) = item,
                  case .string(let url) = obj["url"] else { return nil }
            let name: String?
            if case .string(let n) = obj["name"] { name = n } else { name = nil }
            return FigmaLink(url: url, name: name)
        }
    }

    /// Encode `[FigmaLink]` → `WidgetJSONValue.array`.
    static func encode(_ links: [FigmaLink]) -> WidgetJSONValue {
        .array(links.map { link in
            .object(["url": .string(link.url), "name": link.name.map { .string($0) } ?? .null])
        })
    }
}

// MARK: - FigmaWidget

/// The Figma widget — pre-built, part of the figma plugin.
///
/// Widget id:  `figma`
/// Storage ns: reads and writes namespace `figma` (own namespace, id == "figma").
///   figma/links — JSON array of { url, name } (multiple files, one tab each).
@Observable
@MainActor
final class FigmaWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "figma"
    let title = "Figma"
    let icon = "square.on.square.dashed"   // fallback; iconImageData is the brand mark
    var iconImageData: Data? { FigmaWidget.brandPNG }

    /// Session surfaces only — attached files belong to a session, not Home.
    var enabledLayouts: Set<WidgetLayout> { Set(WidgetLayout.allCases).subtracting([.home]) }

    /// Figma pages are rendered by this widget. Receiving a URL only changes the
    /// in-memory BrowserSurface destination; attach remains an explicit
    /// storage-writing action.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(figmaURLPattern)],
                perform: { [weak self] url in
                    self?.openLink(url)
                }
            ),
        ]
    }

    // MARK: - Observed state

    /// The attached Figma files (figma/links storage). Empty = paste-URL form.
    var links: [FigmaLink] = []
    /// A transient Open-Link destination, shown as a tab but not persisted.
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
            await self?.loadAndSyncLinks()
        }
    }

    func deactivate() {
        services = nil
        browserModel = nil
        openedLinkURL = nil
        isLoading = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(FigmaWidgetMainView(widget: self, services: services))
    }

    // MARK: - Load from storage

    func loadAndSyncLinks() async {
        guard let services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await services.storage.get(namespace: "figma", key: "links")
            links = value.map(FigmaLink.decode(from:)) ?? []
        } catch {
            // Storage unavailable (Home surface, no task) — stay in empty state.
            links = []
        }
        syncTabs()
    }

    /// Re-read `figma/links` and, when it changed out-of-band (an agent, the CLI,
    /// or `task42 storage set figma/links`), append the new tab(s) and focus the
    /// newest — live, without a close/reopen. A no-op when the URL set is
    /// unchanged, so open tabs never thrash on the poll.
    func refreshFromStorage() async {
        guard let services else { return }
        let latest: [FigmaLink]
        do {
            let value = try await services.storage.get(namespace: "figma", key: "links")
            latest = value.map(FigmaLink.decode(from:)) ?? []
        } catch {
            return  // storage briefly unavailable — keep the current tabs
        }
        let currentURLs = links.map(\.url)
        let latestURLs = latest.map(\.url)
        guard currentURLs != latestURLs else { return }

        let hadTabs = !currentURLs.isEmpty
        let addedURLs = latestURLs.filter { !currentURLs.contains($0) }
        links = latest
        syncTabs()
        if hadTabs, let newest = addedURLs.last {
            browserModel?.selectTab(stableTabID(for: newest))
        }
    }

    // MARK: - Tab sync

    /// Sync the BrowserSurface model's tab list from `displayedURLs` — one tab
    /// per attached file (plus a transient opened-link tab).
    func syncTabs() {
        guard let model = BrowserSurface.model(forKey: id) else { return }
        let tabs: [BrowserTab] = displayedURLs.map { url in
            let urlString = url.absoluteString
            let label = nameForURL(urlString) ?? (url.host ?? urlString)
            return BrowserTab(id: stableTabID(for: urlString), url: url, title: label, icon: "square.on.square.dashed")
        }
        model.replaceTabs(tabs)
    }

    /// Attached file URLs followed by the transient Open-Link destination, if it
    /// is not already attached.
    var displayedURLs: [URL] {
        var urls = links.compactMap { URL(string: $0.url) }
        if let opened = openedLinkURL,
           !links.contains(where: { $0.url == opened.absoluteString }) {
            urls.append(opened)
        }
        return urls
    }

    /// The display name for an attached URL (stored name first, else derived).
    private func nameForURL(_ urlString: String) -> String? {
        if let link = links.first(where: { $0.url == urlString }), let n = link.name, !n.isEmpty {
            return n
        }
        return figmaDisplayName(from: urlString)
    }

    /// Navigate to a Figma file without attaching it — shows it as a tab.
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

    /// Validate and attach a Figma file URL. Returns an error string on failure,
    /// nil on success (or when already attached).
    func attach(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "URL cannot be empty." }
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            return "Not a valid URL. Expected https://www.figma.com/design/<key>/<name>."
        }
        guard isFigmaURL(trimmed) else {
            return "Not a Figma URL. Expected a figma.com file, design, board, or proto link."
        }
        guard !links.contains(where: { $0.url == trimmed }) else { return nil }

        var updated = links
        updated.append(FigmaLink(url: trimmed, name: figmaDisplayName(from: trimmed)))
        return await writeLinks(updated)
    }

    // MARK: - Detach

    func detach(tabID: UUID) async {
        guard let urlString = urlForTabID(tabID) else { return }
        // A transient opened-link tab (not attached) → just drop it.
        if !links.contains(where: { $0.url == urlString }) {
            if openedLinkURL?.absoluteString == urlString { openedLinkURL = nil }
            tabIDs.removeValue(forKey: urlString)
            syncTabs()
            return
        }
        let updated = links.filter { $0.url != urlString }
        tabIDs.removeValue(forKey: urlString)
        _ = await writeLinks(updated)
    }

    // MARK: - Write links to storage

    /// Persist the updated link list to `figma/links` and refresh `self.links`.
    private func writeLinks(_ updated: [FigmaLink]) async -> String? {
        guard let services else { return "Widget not active." }
        do {
            try await services.storage.set(key: "links", value: FigmaLink.encode(updated))
        } catch {
            return "Failed to write link list: \(error.localizedDescription)"
        }
        links = updated
        syncTabs()
        return nil
    }
}

// MARK: - FigmaWidgetMainView

/// Root view dispatched from `makeView`. Shows the empty-state form when no file
/// is attached, or the tabbed BrowserSurface otherwise.
@MainActor
private struct FigmaWidgetMainView: View {
    let widget: FigmaWidget
    let services: SessionServices

    var body: some View {
        Group {
            if widget.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if widget.displayedURLs.isEmpty {
                FigmaEmptyStateView(widget: widget, services: services)
            } else {
                FigmaBrowserView(widget: widget, services: services)
            }
        }
        // Live tab-reconcile, scoped to the view being on screen (matches jira):
        // an immediate check on appear, then poll for out-of-band figma/links
        // changes only while visible.
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

// MARK: - FigmaBrowserView

/// Renders the BrowserSurface with one tab per attached Figma file. The chrome's
/// `+` opens an attach sheet; a tab's `×` detaches the file.
@MainActor
private struct FigmaBrowserView: View {
    let widget: FigmaWidget
    let services: SessionServices

    private var firstURL: URL {
        widget.displayedURLs.first ?? URL(string: "https://www.figma.com")!
    }

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(
                url: firstURL,
                selector: "",
                dataStoreKey: "browser",
                title: "Figma",
                icon: "square.on.square.dashed"
            ),
            cacheKey: widget.id,
            configure: { [weak widget] model in
                guard let widget else { return }
                widget.browserModel = model
                widget.syncTabs()
                model.onNewTab = { [weak widget] in
                    widget?.showingAttachForm = true
                }
                model.onTabClosed = { [weak widget] tabID in
                    Task { await widget?.detach(tabID: tabID) }
                }
            }
        )
        .onChange(of: widget.displayedURLs.map(\.absoluteString)) { _, _ in
            widget.syncTabs()
        }
        .sheet(isPresented: Binding(
            get: { widget.showingAttachForm },
            set: { widget.showingAttachForm = $0 }
        )) {
            FigmaAttachSheet(widget: widget, services: services)
        }
    }
}

// MARK: - FigmaEmptyStateView

/// Shown when no file is attached. Paste a Figma URL to attach the first file.
@MainActor
private struct FigmaEmptyStateView: View {
    let widget: FigmaWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var assigning = false

    var body: some View {
        VStack(spacing: DT.s16) {
            FigmaBrandMark(size: 32)

            Text("No Figma file")
                .font(.system(size: DT.f13, weight: .medium))

            Text("Paste a Figma file URL to embed it here. Add more later with the + in the tab bar. Sign in to Figma once and the session is kept. The agent can read attached files via the Figma MCP.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://www.figma.com/design/<key>/<name>", text: $draftURL)
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

// MARK: - FigmaAttachSheet

/// Modal sheet shown when the `+` button is pressed in the chrome row.
@MainActor
private struct FigmaAttachSheet: View {
    let widget: FigmaWidget
    let services: SessionServices

    @State private var draftURL: String = ""
    @State private var errorMessage: String? = nil
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            FigmaBrandMark(size: 28)

            Text("Attach a Figma file")
                .font(.system(size: DT.f14, weight: .semibold))

            Text("Paste a Figma file URL. A new tab is added and the file is embedded.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: DT.s8) {
                TextField("https://www.figma.com/design/<key>/<name>", text: $draftURL)
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

// MARK: - Figma brand mark

extension FigmaWidget {
    /// The Figma logo rendered to PNG once, for `iconImageData` (menu/header).
    @MainActor static let brandPNG: Data? = renderBrandPNG(size: 64)

    /// Draw the Figma logo — five shapes on a 38×57 grid (unit r = 9.5): three
    /// left-column half-pills (red rounded-left, purple rounded-left) + salmon
    /// rounded-right top, plus the blue (mid-right) and green (bottom-left) full
    /// circles — into an NSImage and return PNG data.
    @MainActor static func renderBrandPNG(size: CGFloat) -> Data? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let pad = size * 0.14
        let s = min((size - 2 * pad) / 38.0, (size - 2 * pad) / 57.0)
        let ox = (size - 38 * s) / 2
        let oy = (size - 57 * s) / 2
        let r = 9.5 * s
        // SVG (y-down, top=0) → NSImage (y-up).
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (57 - y) * s) }

        let red    = NSColor(srgbRed: 0.949, green: 0.306, blue: 0.118, alpha: 1) // F24E1E
        let salmon = NSColor(srgbRed: 1.000, green: 0.447, blue: 0.384, alpha: 1) // FF7262
        let purple = NSColor(srgbRed: 0.635, green: 0.349, blue: 1.000, alpha: 1) // A259FF
        let blue   = NSColor(srgbRed: 0.102, green: 0.737, blue: 0.996, alpha: 1) // 1ABCFE
        let green  = NSColor(srgbRed: 0.039, green: 0.812, blue: 0.514, alpha: 1) // 0ACF83

        // Half-pill rounded on the LEFT of a 19×19 SVG cell at (x0, yTop).
        func leftPill(x0: CGFloat, yTop: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: pt(x0 + 19, yTop + 19))         // bottom-right
            p.line(to: pt(x0 + 19, yTop))              // top-right
            p.line(to: pt(x0 + 9.5, yTop))             // top of semicircle
            p.appendArc(withCenter: pt(x0 + 9.5, yTop + 9.5), radius: r,
                        startAngle: 90, endAngle: 270, clockwise: false)  // left bulge
            p.close()
            return p
        }
        // Half-pill rounded on the RIGHT of a 19×19 SVG cell at (x0, yTop).
        func rightPill(x0: CGFloat, yTop: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: pt(x0, yTop + 19))              // bottom-left
            p.line(to: pt(x0, yTop))                   // top-left
            p.line(to: pt(x0 + 9.5, yTop))             // top of semicircle
            p.appendArc(withCenter: pt(x0 + 9.5, yTop + 9.5), radius: r,
                        startAngle: 90, endAngle: 270, clockwise: true)   // right bulge
            p.close()
            return p
        }
        func circle(x0: CGFloat, yTop: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(origin: pt(x0, yTop + 19), size: NSSize(width: 19 * s, height: 19 * s)))
        }

        red.setFill();    leftPill(x0: 0, yTop: 0).fill()
        salmon.setFill(); rightPill(x0: 19, yTop: 0).fill()
        purple.setFill(); leftPill(x0: 0, yTop: 19).fill()
        blue.setFill();   circle(x0: 19, yTop: 19).fill()
        green.setFill();  circle(x0: 0, yTop: 38).fill()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// The Figma brand mark as a SwiftUI view (renders the shared PNG; falls back to
/// a neutral glyph if rendering ever fails).
private struct FigmaBrandMark: View {
    let size: CGFloat
    var body: some View {
        if let data = FigmaWidget.brandPNG, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(DT.textTertiary)
        }
    }
}

// MARK: - Widget entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects.
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable).

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(FigmaWidget())
    }
    return result
}
