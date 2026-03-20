import Foundation

struct ChunkPlanner {
    var maxFileBatchSize: Int = 500
    var maxItemsPerChunk: Int = 5_000
    var maxExpectedBytesPerChunk: Int64 = 2 * 1024 * 1024 * 1024

    func plan(items: [ScannedItem]) -> [ChunkManifest] {
        let nonRootItems = items.filter { $0.pathComponents.count > 1 || $0.kind == .directory && !$0.pathComponents.isEmpty }
        let rootFiles = items
            .filter { $0.pathComponents.count == 1 && $0.kind != .directory }
            .sorted { $0.relativePath < $1.relativePath }
        let rootDirectories = Set(
            nonRootItems.compactMap { $0.pathComponents.first }
        )

        var chunks: [ChunkManifest] = []
        for batch in rootFiles.chunked(into: maxFileBatchSize) {
            chunks.append(makeFileBatch(anchorRelativePath: nil, items: batch))
        }
        for rootDirectory in rootDirectories.sorted() {
            let subtree = items.filter { item in
                item.relativePath == rootDirectory || item.relativePath.hasPrefix(rootDirectory + "/")
            }
            chunks.append(contentsOf: splitDirectory(anchorRelativePath: rootDirectory, items: subtree))
        }
        return chunks.sorted { lhs, rhs in
            (lhs.anchorRelativePath ?? "") < (rhs.anchorRelativePath ?? "")
        }
    }

    private func splitDirectory(anchorRelativePath: String, items: [ScannedItem]) -> [ChunkManifest] {
        let expectedBytes = items.expectedBytes
        if items.count <= maxItemsPerChunk && expectedBytes <= maxExpectedBytesPerChunk {
            return [ChunkManifest(
                id: UUID(),
                anchorRelativePath: anchorRelativePath,
                kind: .directorySubtree,
                relativePaths: items.map(\.relativePath).sorted(),
                expectedBytes: expectedBytes,
                state: .pending,
                recoveryMode: .direct,
                lastError: nil
            )]
        }

        let directFiles = items
            .filter { $0.kind != .directory && $0.parentRelativePath == anchorRelativePath }
            .sorted { $0.relativePath < $1.relativePath }
        let directDirectories = Set(
            items
                .compactMap { item -> String? in
                    guard item.kind == .directory, item.parentRelativePath == anchorRelativePath else { return nil }
                    return item.relativePath
                }
        )

        if directDirectories.isEmpty {
            return directFiles.chunked(into: maxFileBatchSize).map { batch in
                makeFileBatch(anchorRelativePath: anchorRelativePath, items: batch)
            }
        }

        var chunks: [ChunkManifest] = []
        if !directFiles.isEmpty {
            directFiles.chunked(into: maxFileBatchSize).forEach { batch in
                chunks.append(makeFileBatch(anchorRelativePath: anchorRelativePath, items: batch))
            }
        }
        for directory in directDirectories.sorted() {
            let subtree = items.filter { item in
                item.relativePath == directory || item.relativePath.hasPrefix(directory + "/")
            }
            chunks.append(contentsOf: splitDirectory(anchorRelativePath: directory, items: subtree))
        }
        return chunks
    }

    private func makeFileBatch(anchorRelativePath: String?, items: [ScannedItem]) -> ChunkManifest {
        ChunkManifest(
            id: UUID(),
            anchorRelativePath: anchorRelativePath,
            kind: .fileBatch,
            relativePaths: items.map(\.relativePath),
            expectedBytes: items.expectedBytes,
            state: .pending,
            recoveryMode: .direct,
            lastError: nil
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
