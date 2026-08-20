import Foundation

enum GitHubWidgetLinkSupport {
    static let pullRequestPattern =
        #"(?i)^https?://github\.com/[^/?#]+/[^/?#]+/pull/[0-9]+(?:[/?#].*)?$"#

    /// Compose task-attached PRs with one transient Open Link destination.
    /// The input array is never mutated and an already-attached URL is not
    /// duplicated.
    static func displayedURLs(attached: [URL], opened: URL?) -> [URL] {
        guard let opened,
              !attached.contains(where: { $0.absoluteString == opened.absoluteString })
        else { return attached }
        return attached + [opened]
    }
}
