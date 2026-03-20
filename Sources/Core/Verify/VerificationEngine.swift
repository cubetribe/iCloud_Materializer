import Foundation

actor VerificationEngine {
    private let fileManager = FileManager.default
    private let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    func verify(expectedItems: [ScannedItem], at root: URL) throws -> VerificationResult {
        let expectedMap = Dictionary(uniqueKeysWithValues: expectedItems.map { ($0.relativePath, $0) })
        let actualMap = try buildActualInventory(root: root)
        var mismatches: [String] = []
        var verifiedBytes: Int64 = 0

        for item in expectedItems {
            guard let actual = actualMap[item.relativePath] else {
                mismatches.append("Missing item: \(item.relativePath)")
                continue
            }
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

        let extras = actualMap.keys.filter { expectedMap[$0] == nil && !shouldIgnoreExtra(path: $0) }
        extras.forEach { mismatches.append("Unexpected item: \($0)") }

        if !mismatches.isEmpty {
            throw PipelineError.verificationFailed(mismatches)
        }

        return VerificationResult(verifiedCount: expectedItems.count, verifiedBytes: verifiedBytes)
    }

    private func buildActualInventory(root: URL) throws -> [String: ScannedItem] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        var items: [String: ScannedItem] = [:]
        for case let url as URL in enumerator {
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

    private func shouldIgnoreExtra(path: String) -> Bool {
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        return lastComponent == ".DS_Store" || lastComponent.hasPrefix("._")
    }
}
