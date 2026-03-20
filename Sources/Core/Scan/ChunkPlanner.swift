import Foundation

struct ChunkPlanner {
    var maxFileBatchSize: Int = 500
    var maxItemsPerChunk: Int = 5_000
    var maxExpectedBytesPerChunk: Int64 = 2 * 1024 * 1024 * 1024
    var maxPendingHydrationsPerChunk: Int = 256

    func plan(items: [ScannedItem], priorityPolicy: TransferPriorityPolicy = .naturalOrder) -> [ChunkManifest] {
        let rootFiles = items.filter { $0.pathComponents.count == 1 && $0.kind != .directory }
        let sortedRootFiles = priorityPolicy.sort(items: rootFiles)
        let rootDirectorySubtrees = makeRootDirectorySubtrees(items: items)
        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })

        var chunks: [ChunkManifest] = []
        for batch in sortedRootFiles.chunked(into: maxFileBatchSize) {
            chunks.append(makeFileBatch(anchorRelativePath: nil, items: batch))
        }
        for rootDirectory in rootDirectorySubtrees.keys.sorted() {
            guard let subtree = rootDirectorySubtrees[rootDirectory] else { continue }
            chunks.append(contentsOf: splitDirectory(
                anchorRelativePath: rootDirectory,
                items: subtree,
                priorityPolicy: priorityPolicy
            ))
        }
        return priorityPolicy.sort(chunks: chunks, itemMap: itemMap)
    }

    private func splitDirectory(
        anchorRelativePath: String,
        items: [ScannedItem],
        priorityPolicy: TransferPriorityPolicy
    ) -> [ChunkManifest] {
        if shouldKeepAsSingleChunk(items) {
            return [ChunkManifest(
                id: UUID(),
                anchorRelativePath: anchorRelativePath,
                kind: .directorySubtree,
                relativePaths: items.map(\.relativePath).sorted(),
                expectedBytes: items.expectedBytes,
                state: .pending,
                recoveryMode: .direct,
                lastError: nil
            )]
        }

        let split = splitChildren(of: anchorRelativePath, items: items)
        let sortedDirectFiles = priorityPolicy.sort(items: split.directFiles)
        let sortedDirectDirectories = split.directorySubtrees.keys.sorted { lhs, rhs in
            let lhsBand = priorityPolicy.priority(relativePath: lhs, kind: .directory)
            let rhsBand = priorityPolicy.priority(relativePath: rhs, kind: .directory)
            if lhsBand != rhsBand {
                return lhsBand < rhsBand
            }
            return lhs < rhs
        }

        if split.directorySubtrees.isEmpty {
            return sortedDirectFiles.chunked(into: maxFileBatchSize).map { batch in
                makeFileBatch(anchorRelativePath: anchorRelativePath, items: batch)
            }
        }

        var chunks: [ChunkManifest] = []
        if !sortedDirectFiles.isEmpty {
            sortedDirectFiles.chunked(into: maxFileBatchSize).forEach { batch in
                chunks.append(makeFileBatch(anchorRelativePath: anchorRelativePath, items: batch))
            }
        }
        for directory in sortedDirectDirectories {
            guard let subtree = split.directorySubtrees[directory] else { continue }
            chunks.append(contentsOf: splitDirectory(
                anchorRelativePath: directory,
                items: subtree,
                priorityPolicy: priorityPolicy
            ))
        }
        return chunks
    }

    private func shouldKeepAsSingleChunk(_ items: [ScannedItem]) -> Bool {
        let expectedBytes = items.expectedBytes
        let pendingHydrations = items.reduce(into: 0) { partial, item in
            if item.kind != .directory && item.isUbiquitous && !item.isLocalReady {
                partial += 1
            }
        }

        return items.count <= maxItemsPerChunk &&
            expectedBytes <= maxExpectedBytesPerChunk &&
            pendingHydrations <= maxPendingHydrationsPerChunk
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

    private func makeRootDirectorySubtrees(items: [ScannedItem]) -> [String: [ScannedItem]] {
        var subtrees: [String: [ScannedItem]] = [:]
        for item in items {
            guard let rootComponent = item.pathComponents.first else { continue }
            if item.pathComponents.count == 1 && item.kind != .directory {
                continue
            }
            subtrees[rootComponent, default: []].append(item)
        }
        return subtrees
    }

    private func splitChildren(of anchorRelativePath: String, items: [ScannedItem]) -> SplitChildren {
        var directFiles: [ScannedItem] = []
        var directorySubtrees: [String: [ScannedItem]] = [:]

        for item in items {
            guard let childPath = immediateChildPath(for: item.relativePath, under: anchorRelativePath) else {
                continue
            }

            if childPath == item.relativePath, item.kind != .directory {
                directFiles.append(item)
            } else {
                directorySubtrees[childPath, default: []].append(item)
            }
        }

        return SplitChildren(directFiles: directFiles, directorySubtrees: directorySubtrees)
    }

    private func immediateChildPath(for relativePath: String, under anchorRelativePath: String) -> String? {
        guard relativePath != anchorRelativePath else { return nil }
        let prefix = anchorRelativePath + "/"
        guard relativePath.hasPrefix(prefix) else { return nil }
        let suffix = relativePath.dropFirst(prefix.count)
        guard let firstComponent = suffix.split(separator: "/").first else { return nil }
        return anchorRelativePath + "/" + firstComponent
    }
}

private struct SplitChildren {
    var directFiles: [ScannedItem]
    var directorySubtrees: [String: [ScannedItem]]
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
