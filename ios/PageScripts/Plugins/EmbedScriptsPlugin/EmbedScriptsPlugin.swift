import Foundation
import PackagePlugin

@main
struct EmbedScriptsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SwiftSourceModuleTarget else { return [] }
        let directory = target.directoryURL.appendingPathComponent("JavaScript", isDirectory: true)
        let scripts = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "js" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !scripts.isEmpty else {
            Diagnostics.error("No JavaScript inputs found in \(directory.path)")
            return []
        }
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("EmbeddedScripts.generated.swift")
        let generator = try context.tool(named: "EmbedScriptsGenerator")
        return [
            .buildCommand(
                displayName: "Embed JavaScript in PageScripts",
                executable: generator.url,
                arguments: ["--output", output.path] + scripts.map(\.path),
                // The directory also invalidates the command when JS files
                // are added or removed, not just when existing files change.
                inputFiles: [directory] + scripts,
                outputFiles: [output]
            ),
        ]
    }
}
