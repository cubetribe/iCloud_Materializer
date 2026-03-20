import Foundation

struct ChunkPlanner {
    var maxFileBatchSize: Int = 500
    var maxItemsPerChunk: Int = 5_000
    var maxExpectedBytesPerChunk: Int64 = 2 * 1024 * 1024 * 1024
    var maxPendingHydrationsPerChunk: Int = 256
    var planningIterationBudgetMultiplier: Int = 4

    func plan(items: [ScannedItem], priorityPolicy: TransferPriorityPolicy = .naturalOrder) -> [ChunkManifest] {
        let rootFiles = items.filter { $0.pathComponents.count == 1 && $0.kind != .directory }
        let sortedRootFiles = priorityPolicy.sort(items: rootFiles)
        let rootDirectorySubtrees = makeRootDirectorySubtrees(items: items)
        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })

        var chunks: [ChunkManifest] = []
        for batch in sortedRootFiles.chunked(into: maxFileBatchSize) {
            chunks.append(makeFileBatch(anchorRelativePath: nil, items: batch))
        }

        var pendingDirectories = rootDirectorySubtrees.keys.sorted().compactMap { anchor -> DirectoryWorkItem? in
            guard let subtree = rootDirectorySubtrees[anchor] else { return nil }
            return DirectoryWorkItem(anchorRelativePath: anchor, items: subtree)
        }

        let planningBudget = max(items.count * max(planningIterationBudgetMultiplier, 1), 1)
        var planningIterations = 0

        while !pendingDirectories.isEmpty {
            let workItem = pendingDirectories.removeFirst()
            planningIterations += 1

            if planningIterations > planningBudget {
                chunks.append(makeDirectoryChunk(anchorRelativePath: workItem.anchorRelativePath, items: workItem.items))
                for remaining in pendingDirectories {
                    chunks.append(makeDirectoryChunk(anchorRelativePath: remaining.anchorRelativePath, items: remaining.items))
                }
                pendingDirectories.removeAll()
                break
            }

            if shouldKeepAsSingleChunk(workItem.items) {
                chunks.append(makeDirectoryChunk(anchorRelativePath: workItem.anchorRelativePath, items: workItem.items))
                continue
            }

            let split = splitChildren(of: workItem.anchorRelativePath, items: workItem.items)
            if let fallbackChunk = fallbackChunkIfSplitDidNotProgress(workItem: workItem, split: split) {
                chunks.append(fallbackChunk)
                continue
            }

            let sortedDirectFiles = priorityPolicy.sort(items: split.directFiles)
            if !sortedDirectFiles.isEmpty {
                sortedDirectFiles.chunked(into: maxFileBatchSize).forEach { batch in
                    chunks.append(makeFileBatch(anchorRelativePath: workItem.anchorRelativePath, items: batch))
                }
            }

            let sortedDirectDirectories = split.directorySubtrees.keys.sorted { lhs, rhs in
                let lhsBand = priorityPolicy.priority(relativePath: lhs, kind: .directory)
                let rhsBand = priorityPolicy.priority(relativePath: rhs, kind: .directory)
                if lhsBand != rhsBand {
                    return lhsBand < rhsBand
                }
                return lhs < rhs
            }

            for directory in sortedDirectDirectories {
                guard let subtree = split.directorySubtrees[directory] else { continue }
                pendingDirectories.append(DirectoryWorkItem(anchorRelativePath: directory, items: subtree))
            }
        }

        return priorityPolicy.sort(chunks: chunks, itemMap: itemMap)
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

    private func fallbackChunkIfSplitDidNotProgress(
        workItem: DirectoryWorkItem,
        split: SplitChildren
    ) -> ChunkManifest? {
        guard split.directFiles.isEmpty else { return nil }
        guard split.directorySubtrees.count == 1,
              let onlySubtree = split.directorySubtrees.values.first,
              onlySubtree.count >= workItem.items.count else {
            return nil
        }

        // Protect against pathological directory shapes that would otherwise recurse without reducing work.
        return makeDirectoryChunk(anchorRelativePath: workItem.anchorRelativePath, items: workItem.items)
    }

    private func makeDirectoryChunk(anchorRelativePath: String, items: [ScannedItem]) -> ChunkManifest {
        ChunkManifest(
            id: UUID(),
            anchorRelativePath: anchorRelativePath,
            kind: .directorySubtree,
            relativePaths: items.map(\.relativePath).sorted(),
            expectedBytes: items.expectedBytes,
            state: .pending,
            recoveryMode: .direct,
            lastError: nil
        )
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

private struct DirectoryWorkItem {
    var anchorRelativePath: String
    var items: [ScannedItem]
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
