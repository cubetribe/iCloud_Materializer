import Foundation

actor ZipEngine {
    private let fileManager = FileManager.default

    func archiveSource(
        sourceRoot: URL,
        expectedItems: [ScannedItem],
        archiveRoot: URL,
        configuration: JobConfiguration,
        downloadEngine: DownloadEngine,
        hydrationSession: HydrationSession,
        pauseController: PauseController,
        onProgress: @escaping @Sendable (String) async -> Void
    ) async throws -> URL {
        _ = try await downloadEngine.materialize(
            items: expectedItems,
            sourceRoot: sourceRoot,
            configuration: configuration,
            pauseController: pauseController,
            hydrationSession: hydrationSession,
            onEvent: { event in
                switch event {
                case .evaluating(let item), .ready(let item, _), .deferred(let item, _):
                    await onProgress(item.relativePath)
                }
            }
        )

        let temporaryZipURL = archiveRoot.appendingPathComponent("\(sourceRoot.lastPathComponent).zip", isDirectory: false)
        if fileManager.fileExists(atPath: temporaryZipURL.path) {
            try fileManager.removeItem(at: temporaryZipURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", sourceRoot.path, temporaryZipURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PipelineError.zipFailed(errorText.isEmpty ? "ditto failed to create archive." : errorText)
        }

        let attributes = try fileManager.attributesOfItem(atPath: temporaryZipURL.path)
        let size = attributes[.size] as? NSNumber ?? 0
        guard size.int64Value > 0 else {
            throw PipelineError.zipFailed("The archive was created with zero bytes.")
        }

        let finalZipURL = configuration.finalArchiveURL ?? sourceRoot.appendingPathComponent("\(sourceRoot.lastPathComponent).zip", isDirectory: false)
        try fileManager.createDirectory(at: finalZipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: finalZipURL.path) else {
            throw PipelineError.zipFailed("A ZIP already exists at \(finalZipURL.path)")
        }
        try fileManager.moveItem(at: temporaryZipURL, to: finalZipURL)
        return finalZipURL
    }
}
