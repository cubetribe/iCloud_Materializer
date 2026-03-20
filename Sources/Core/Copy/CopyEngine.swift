import Foundation

actor CopyEngine {
    private let fileManager = FileManager.default

    enum Event: Sendable {
        case preparing(ScannedItem)
        case copied(ScannedItem)
    }

    func copyChunk(
        items: [ScannedItem],
        sourceRoot: URL,
        stageRoot: URL,
        priorityPolicy: TransferPriorityPolicy,
        pauseController: PauseController,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) async throws {
        if fileManager.fileExists(atPath: stageRoot.path) {
            try fileManager.removeItem(at: stageRoot)
        }
        try fileManager.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        let sortedItems = priorityPolicy.sort(items: items)
        for item in sortedItems {
            try await pauseController.checkpoint()
            await onEvent(.preparing(item))
            let sourceURL = sourceRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            let destinationURL = stageRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            switch item.kind {
            case .directory:
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            case .symlink:
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                let target: String
                if let symlinkDestination = item.symlinkDestination {
                    target = symlinkDestination
                } else {
                    target = try fileManager.destinationOfSymbolicLink(atPath: sourceURL.path)
                }
                try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: target)
            case .file:
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try coordinatedCopy(from: sourceURL, to: destinationURL)
            }
            await onEvent(.copied(item))
        }
    }

    private func coordinatedCopy(from sourceURL: URL, to destinationURL: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { readURL in
            do {
                try fileManager.copyItem(at: readURL, to: destinationURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let operationError {
            throw operationError
        }
    }
}
