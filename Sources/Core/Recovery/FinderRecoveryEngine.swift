import Foundation

actor FinderRecoveryEngine {
    private let fileManager = FileManager.default

    func recoverChunk(chunk: ChunkManifest, sourceRoot: URL, stageRoot: URL) async throws {
        if fileManager.fileExists(atPath: stageRoot.path) {
            try fileManager.removeItem(at: stageRoot)
        }
        try fileManager.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        switch chunk.kind {
        case .directorySubtree:
            guard let anchor = chunk.anchorRelativePath else {
                throw PipelineError.finderRecoveryFailed("Directory chunk is missing an anchor path.")
            }
            let sourceURL = sourceRoot.appendingPathComponent(anchor, isDirectory: true)
            let destinationParent = stageRoot.appendingPathComponent((anchor as NSString).deletingLastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
            try runAppleScriptCopy(sources: [sourceURL], destinationDirectory: destinationParent)
        case .fileBatch:
            let destinationDirectory: URL
            if let anchor = chunk.anchorRelativePath {
                destinationDirectory = stageRoot.appendingPathComponent(anchor, isDirectory: true)
            } else {
                destinationDirectory = stageRoot
            }
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let sourceURLs = chunk.relativePaths.map { sourceRoot.appendingPathComponent($0, isDirectory: false) }
            try runAppleScriptCopy(sources: sourceURLs, destinationDirectory: destinationDirectory)
        }
    }

    private func runAppleScriptCopy(sources: [URL], destinationDirectory: URL) throws {
        let sourceList = sources
            .map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")
        let script = """
        tell application "Finder"
            with timeout of 86400 seconds
                duplicate {\(sourceList)} to POSIX file "\(destinationDirectory.path.replacingOccurrences(of: "\"", with: "\\\""))"
            end timeout
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PipelineError.finderRecoveryFailed(errorText.isEmpty ? "Finder recovery failed." : errorText)
        }
    }
}
