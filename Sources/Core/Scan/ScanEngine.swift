import Foundation

actor ScanEngine {
    private let fileManager = FileManager.default
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .nameKey,
        .isHiddenKey
    ]

    func scan(
        sourceRoot: URL,
        transferPolicy: TransferPolicy,
        onItem: (@Sendable (ScannedItem) async -> Void)? = nil
    ) async throws -> [ScannedItem] {
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw PipelineError.copyFailed(sourceRoot.path)
        }

        var items: [ScannedItem] = []
        while let url = enumerator.nextObject() as? URL {
            let relativePath = normalizedRelativePath(for: url, sourceRoot: sourceRoot)
            guard !relativePath.isEmpty else { continue }
            let values = try url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values.isDirectory ?? false
            let isSymlink = values.isSymbolicLink ?? false
            let kind: ItemKind = isSymlink ? .symlink : (isDirectory ? .directory : .file)
            switch transferPolicy.scanDecision(relativePath: relativePath, kind: kind) {
            case .include:
                break
            case .excludeItem:
                continue
            case .excludeDescendants:
                enumerator.skipDescendants()
                continue
            }
            let isUbiquitous = values.isUbiquitousItem ?? false
            let downloadStatus = values.ubiquitousItemDownloadingStatus
            let fileSize = Int64(values.fileSize ?? 0)
            let isLocalReady = Self.isLocallyAvailable(isUbiquitous: isUbiquitous, downloadStatus: downloadStatus)
            let symlinkDestination: String?
            if isSymlink {
                symlinkDestination = try? fileManager.destinationOfSymbolicLink(atPath: url.path)
            } else {
                symlinkDestination = nil
            }
            let item = ScannedItem(
                id: UUID(),
                relativePath: relativePath,
                kind: kind,
                expectedSize: fileSize,
                isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
                isUbiquitous: isUbiquitous,
                isLocalReady: isLocalReady,
                downloadStatusRaw: downloadStatus?.rawValue,
                symlinkDestination: symlinkDestination,
                state: isLocalReady ? .localReady : .pending,
                lastError: nil
            )
            items.append(item)
            if let onItem {
                await onItem(item)
            }
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    static func refreshedItem(at sourceURL: URL, relativePath: String) throws -> ScannedItem {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .isHiddenKey
        ]
        let values = try sourceURL.resourceValues(forKeys: resourceKeys)
        let isDirectory = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let kind: ItemKind = isSymlink ? .symlink : (isDirectory ? .directory : .file)
        let isUbiquitous = values.isUbiquitousItem ?? false
        let status = values.ubiquitousItemDownloadingStatus
        let localReady = isLocallyAvailable(isUbiquitous: isUbiquitous, downloadStatus: status)
        return ScannedItem(
            id: UUID(),
            relativePath: relativePath,
            kind: kind,
            expectedSize: Int64(values.fileSize ?? 0),
            isHidden: values.isHidden ?? sourceURL.lastPathComponent.hasPrefix("."),
            isUbiquitous: isUbiquitous,
            isLocalReady: localReady,
            downloadStatusRaw: status?.rawValue,
            symlinkDestination: isSymlink ? (try? FileManager.default.destinationOfSymbolicLink(atPath: sourceURL.path)) : nil,
            state: localReady ? .localReady : .pending,
            lastError: nil
        )
    }

    static func isLocallyAvailable(isUbiquitous: Bool, downloadStatus: URLUbiquitousItemDownloadingStatus?) -> Bool {
        guard isUbiquitous else { return true }
        guard let downloadStatus else { return false }
        return downloadStatus == .current || downloadStatus == .downloaded
    }

    private func normalizedRelativePath(for url: URL, sourceRoot: URL) -> String {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(sourcePath) else { return url.lastPathComponent }
        let startIndex = itemPath.index(itemPath.startIndex, offsetBy: sourcePath.count)
        let raw = String(itemPath[startIndex...])
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
