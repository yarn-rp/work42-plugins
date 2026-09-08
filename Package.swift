// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Work42Plugins",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PluginLinkSupport", targets: ["PluginLinkSupport"]),
    ],
    targets: [
        .target(
            name: "PluginLinkSupport",
            path: ".",
            exclude: [
                "LICENSE",
                "README.md",
                "Tests",
                "default.profraw",
                "github/README.md",
                "github/plugin.yaml",
                "github/skills",
                "github/tab-templates",
                "github/widgets/github/SKILL.md",
                "github/widgets/github/Sources/Widget.swift",
                "github/widgets/github-prs",
                "jira/README.md",
                "jira/plugin.yaml",
                "jira/skills",
                "jira/tab-templates",
                "jira/widgets/jira/SKILL.md",
                "jira/widgets/jira/Sources/Widget.swift",
                "jira/widgets/jira-my-issues",
                "figma/README.md",
                "figma/plugin.yaml",
                "figma/skills",
                "figma/tab-templates",
                "figma/widgets/figma/SKILL.md",
                "figma/widgets/figma/Sources/Widget.swift",
            ],
            sources: [
                "github/widgets/github/Sources/GitHubLinkSupport.swift",
                "jira/widgets/jira/Sources/JiraLinkSupport.swift",
            ]
        ),
        .testTarget(
            name: "PluginLinkSupportTests",
            dependencies: ["PluginLinkSupport"],
            path: "Tests/PluginLinkSupportTests"
        ),
    ]
)
