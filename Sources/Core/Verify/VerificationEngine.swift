import Foundation

struct VerificationEngine: Sendable {
    private let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    func verify(
        expectedItems: [ScannedItem],
        at root: URL,
        pauseController: PauseController? = nil,
        onProgress: (@Sendable (String) async -> Void)? = nil
    ) async throws -> VerificationResult {
        let fileManager = FileManager.default
        let expectedMap = Dictionary(uniqueKeysWithValues: expectedItems.map { ($0.relativePath, $0) })
        let actualMap = try await buildActualInventory(root: root, fileManager: fileManager, pauseController: pauseController)
        let canonicalExpectedPaths = canonicalPathLookup(for: expectedItems.map(\.relativePath))
        let canonicalActualPaths = canonicalPathLookup(for: Array(actualMap.keys))
        let allowedAncestorDirectories = ancestorScaffoldDirectories(for: expectedItems)
        var mismatches: [String] = []
        var verifiedBytes: Int64 = 0
        var matchedActualPaths: Set<String> = []

        for item in expectedItems {
            try await checkpoint(pauseController)
            if let onProgress {
                await onProgress(item.relativePath)
            }
            try await checkpoint(pauseController)
            guard let match = resolveActualMatch(
                for: item.relativePath,
                actualMap: actualMap,
                canonicalExpectedPaths: canonicalExpectedPaths,
                canonicalActualPaths: canonicalActualPaths,
                matchedActualPaths: matchedActualPaths
            ) else {
                mismatches.append("Missing item: \(item.relativePath)")
                continue
            }
            let actual = match.item
            matchedActualPaths.insert(match.path)
            switch item.kind {
            case .directory:
                if actual.kind != .directory {
                    mismatches.append("Expected directory: \(item.relativePath)")
                }
            case .symlink:
                if actual.kind != .symlink {
                    mismatches.append("Expected symlink: \(item.relativePath)")
                } else if item.symlinkDestination != actual.symlinkDestination {
                    mismatches.append("Symlink target mismatch: \(item.relativePath)")
                }
            case .file:
                if actual.kind != .file {
                    mismatches.append("Expected file: \(item.relativePath)")
                } else if actual.expectedSize != item.expectedSize {
                    mismatches.append("Size mismatch: \(item.relativePath) expected \(item.expectedSize) got \(actual.expectedSize)")
                } else {
                    verifiedBytes += item.expectedSize
                }
            }
        }

        let extras = actualMap.keys.filter { path in
            guard !matchedActualPaths.contains(path), expectedMap[path] == nil, let actualItem = actualMap[path] else {
                return false
            }
            return !shouldIgnoreExtra(
                path: path,
                actualItem: actualItem,
                allowedAncestorDirectories: allowedAncestorDirectories
            )
        }
        extras.forEach { mismatches.append("Unexpected item: \($0)") }

        if !mismatches.isEmpty {
            throw PipelineError.verificationFailed(mismatches)
        }

        return VerificationResult(verifiedCount: expectedItems.count, verifiedBytes: verifiedBytes)
    }

    private func resolveActualMatch(
        for expectedPath: String,
        actualMap: [String: ScannedItem],
        canonicalExpectedPaths: [String: [String]],
        canonicalActualPaths: [String: [String]],
        matchedActualPaths: Set<String>
    ) -> (path: String, item: ScannedItem)? {
        if let exact = actualMap[expectedPath] {
            return (expectedPath, exact)
        }

        let canonicalPath = canonicalPathKey(for: expectedPath)
        guard
            let expectedCandidates = canonicalExpectedPaths[canonicalPath],
            expectedCandidates.count == 1,
            let actualCandidates = canonicalActualPaths[canonicalPath],
            actualCandidates.count == 1,
            let actualPath = actualCandidates.first,
            matchedActualPaths.contains(actualPath) == false,
            let actual = actualMap[actualPath]
        else {
            return nil
        }

        return (actualPath, actual)
    }

    private func buildActualInventory(
        root: URL,
        fileManager: FileManager,
        pauseController: PauseController?
    ) async throws -> [String: ScannedItem] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        var items: [String: ScannedItem] = [:]
        while let url = enumerator.nextObject() as? URL {
            try await checkpoint(pauseController)
            let relativePath = normalizedRelativePath(for: url, root: root)
            guard !relativePath.isEmpty else { continue }
            let values = try url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values.isDirectory ?? false
            let isSymlink = values.isSymbolicLink ?? false
            let kind: ItemKind = isSymlink ? .symlink : (isDirectory ? .directory : .file)
            let symlinkDestination = isSymlink ? (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) : nil
            items[relativePath] = ScannedItem(
                id: UUID(),
                relativePath: relativePath,
                kind: kind,
                expectedSize: Int64(values.fileSize ?? 0),
                isHidden: url.lastPathComponent.hasPrefix("."),
                isUbiquitous: false,
                isLocalReady: true,
                downloadStatusRaw: nil,
                symlinkDestination: symlinkDestination,
                state: .copied,
                lastError: nil
            )
            try await checkpoint(pauseController)
        }
        return items
    }

    private func normalizedRelativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        let startIndex = itemPath.index(itemPath.startIndex, offsetBy: rootPath.count)
        return String(itemPath[startIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func shouldIgnoreExtra(
        path: String,
        actualItem: ScannedItem,
        allowedAncestorDirectories: Set<String>
    ) -> Bool {
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        if lastComponent == ".DS_Store" || lastComponent.hasPrefix("._") {
            return true
        }

        return actualItem.kind == .directory && allowedAncestorDirectories.contains(path)
    }

    private func ancestorScaffoldDirectories(for expectedItems: [ScannedItem]) -> Set<String> {
        var ancestors: Set<String> = []

        for item in expectedItems {
            let components = item.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }

            for index in 1..<components.count {
                let ancestor = components.prefix(index).joined(separator: "/")
                if ancestor != item.relativePath {
                    ancestors.insert(ancestor)
                }
            }
        }

        return ancestors
    }

    private func canonicalPathLookup(for paths: [String]) -> [String: [String]] {
        Dictionary(grouping: paths, by: canonicalPathKey(for:))
    }

    private func canonicalPathKey(for path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    private func checkpoint(_ pauseController: PauseController?) async throws {
        try Task.checkCancellation()
        if let pauseController {
            try await pauseController.checkpoint()
        }
        try Task.checkCancellation()
    }
}
