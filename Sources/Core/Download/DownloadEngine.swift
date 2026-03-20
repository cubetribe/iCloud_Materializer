import Foundation

actor DownloadEngine {
    private let fileManager = FileManager.default

    enum Event: Sendable {
        case evaluating(ScannedItem)
        case ready(ScannedItem, downloaded: Bool)
    }

    struct Report: Sendable {
        var items: [ScannedItem]
        var downloadedCount: Int
    }

    func materialize(
        items: [ScannedItem],
        sourceRoot: URL,
        configuration: JobConfiguration,
        pauseController: PauseController,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) async throws -> Report {
        var updatedItems: [ScannedItem] = []
        var downloadedCount = 0

        for item in items.sorted(by: { $0.relativePath < $1.relativePath }) {
            try await pauseController.checkpoint()
            await onEvent(.evaluating(item))
            guard item.isUbiquitous, !item.isLocalReady else {
                var readyItem = item
                if readyItem.state == .pending {
                    readyItem.state = .localReady
                }
                updatedItems.append(readyItem)
                await onEvent(.ready(readyItem, downloaded: false))
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
                await onEvent(.ready(resolvedItem, downloaded: true))
            } else {
                throw PipelineError.materializationFailed(item.relativePath)
            }
        }

        return Report(items: updatedItems, downloadedCount: downloadedCount)
    }
}
