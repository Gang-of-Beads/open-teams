// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PageScripts",
    platforms: [.iOS("16.4"), .macOS(.v13)],
    products: [
        .library(name: "PageScripts", targets: ["PageScripts"]),
    ],
    targets: [
        .target(
            name: "PageScripts",
            exclude: ["JavaScript"],
            plugins: [.plugin(name: "EmbedScriptsPlugin")]
        ),
        .executableTarget(name: "EmbedScriptsGenerator"),
        .plugin(
            name: "EmbedScriptsPlugin",
            capability: .buildTool(),
            dependencies: [.target(name: "EmbedScriptsGenerator")]
        ),
    ]
)
