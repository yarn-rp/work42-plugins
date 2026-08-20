import Foundation
import Testing
@testable import PluginLinkSupport

@Suite("Shipped plugin link handling")
struct PluginLinkSupportTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("GitHub claims pull requests and preserves route fragments")
    func githubMatcher() throws {
        let regex = try Regex(GitHubWidgetLinkSupport.pullRequestPattern)

        #expect("https://github.com/yarn-rp/work42/pull/42#discussion_r99".wholeMatch(of: regex) != nil)
        #expect("https://github.com/yarn-rp/work42/pull/42/files?diff=split#L20".wholeMatch(of: regex) != nil)
        #expect("HTTPS://GITHUB.COM/YARN-RP/WORK42/PULL/42".wholeMatch(of: regex) != nil)
        #expect("https://github.com/yarn-rp/work42/issues/42".wholeMatch(of: regex) == nil)
        #expect("https://example.com/yarn-rp/work42/pull/42".wholeMatch(of: regex) == nil)
    }

    @Test("Jira claims Atlassian Cloud URLs and preserves fragments")
    func jiraMatcher() throws {
        let regex = try Regex(JiraWidgetLinkSupport.cloudURLPattern)

        #expect("https://work42.atlassian.net/browse/APP-42#activity".wholeMatch(of: regex) != nil)
        #expect("https://work42.atlassian.net/jira/software/projects/APP/boards/1?selectedIssue=APP-42".wholeMatch(of: regex) != nil)
        #expect("HTTPS://WORK42.ATLASSIAN.NET/BROWSE/APP-42".wholeMatch(of: regex) != nil)
        #expect("https://jira.example.com/browse/APP-42".wholeMatch(of: regex) == nil)
        #expect("https://example.com/".wholeMatch(of: regex) == nil)
    }

    @Test("Transient GitHub navigation does not alter attached PRs")
    func transientGitHubURL() {
        let attached = [URL(string: "https://github.com/yarn-rp/work42/pull/1")!]
        let opened = URL(string: "https://github.com/yarn-rp/work42/pull/2/files#L20")!

        let displayed = GitHubWidgetLinkSupport.displayedURLs(attached: attached, opened: opened)

        #expect(attached.map(\.absoluteString) == ["https://github.com/yarn-rp/work42/pull/1"])
        #expect(displayed.map(\.absoluteString) == [
            "https://github.com/yarn-rp/work42/pull/1",
            "https://github.com/yarn-rp/work42/pull/2/files#L20",
        ])
        #expect(GitHubWidgetLinkSupport.displayedURLs(attached: attached, opened: attached[0]).count == 1)
    }

    @Test("Every shipped widget explicitly declares link intents")
    func explicitDeclarations() throws {
        let github = try source("github/widgets/github/Sources/Widget.swift")
        let githubHome = try source("github/widgets/github-prs/Sources/Widget.swift")
        let jira = try source("jira/widgets/jira/Sources/Widget.swift")
        let jiraHome = try source("jira/widgets/jira-my-issues/Sources/Widget.swift")

        #expect(github.contains("var linkIntents: [WidgetLinkIntentSpec]"))
        #expect(github.contains("GitHubWidgetLinkSupport.pullRequestPattern"))
        #expect(jira.contains("var linkIntents: [WidgetLinkIntentSpec]"))
        #expect(jira.contains("JiraWidgetLinkSupport.cloudURLPattern"))
        #expect(githubHome.contains("let linkIntents: [WidgetLinkIntentSpec] = []"))
        #expect(jiraHome.contains("let linkIntents: [WidgetLinkIntentSpec] = []"))
    }

    @Test("Domain Open Link handlers use navigation-only paths")
    func navigationOnlyHandlers() throws {
        let github = try source("github/widgets/github/Sources/Widget.swift")
        let jira = try source("jira/widgets/jira/Sources/Widget.swift")

        #expect(github.contains("self?.openLink(url)"))
        #expect(jira.contains("self?.openLink(url)"))
        #expect(github.contains("func openLink(_ url: URL)"))
        #expect(jira.contains("func openLink(_ url: URL)"))

        let githubHandler = github.components(separatedBy: "func openLink(_ url: URL)")[1]
            .components(separatedBy: "func stableTabID")[0]
        let jiraHandler = jira.components(separatedBy: "func openLink(_ url: URL)")[1]
            .components(separatedBy: "// MARK: - Load from storage")[0]
        #expect(!githubHandler.contains("storage."))
        #expect(!jiraHandler.contains("storage."))
    }
}
