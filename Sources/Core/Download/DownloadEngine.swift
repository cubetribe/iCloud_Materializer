import Foundation

actor DownloadEngine {
    private let fileManager = FileManager.default

    struct Report: Sendable {
        var items: [ScannedItem]
        var downloadedCount: Int
    }

    func materialize(
        items: [ScannedItem],
        sourceRoot: URL,
        configuration: JobConfiguration,
        pauseController: PauseController,
        onProgress: @escaping @Sendable (String) async -> Void
    ) async throws -> Report {
        var updatedItems: [ScannedItem] = []
        var downloadedCount = 0

        for item in items.sorted(by: { $0.relativePath < $1.relativePath }) {
            try await pauseController.checkpoint()
            await onProgress(item.relativePath)
            guard item.isUbiquitous, !item.isLocalReady else {
                var readyItem = item
                if readyItem.state == .pending {
                    readyItem.state = .localReady
                }
                updatedItems.append(readyItem)
                continue
            }

            let sourceURL = sourceRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            try fileManager.startDownloadingUbiquitousItem(at: sourceURL)

            var resolvedItem: ScannedItem?
            for (attempt, backoff) in configuration.backoffSchedule.enumerated() {
                try await pauseController.checkpoint()
                if attempt > 0 {
                    try await Task.sleep(for: backoff)
                }
                let refreshed = try ScanEngine.refreshedItem(at: sourceURL, relativePath: item.relativePath)
                if refreshed.isLocalReady {
                    resolvedItem = refreshed
                    downloadedCount += 1
                    break
                }
            }

            if let resolvedItem {
                updatedItems.append(resolvedItem)
            } else {
                throw PipelineError.materializationFailed(item.relativePath)
            }
        }

        return Report(items: updatedItems, downloadedCount: downloadedCount)
    }
}
