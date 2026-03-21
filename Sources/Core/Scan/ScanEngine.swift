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

    func scanTopLevel(
        sourceRoot: URL,
        transferPolicy: TransferPolicy,
        pauseController: PauseController? = nil,
        onItem: (@Sendable (ScannedItem) async -> Void)? = nil
    ) async throws -> [ScannedItem] {
        let children = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        )

        var items: [ScannedItem] = []
        for url in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            try await checkpoint(pauseController)
            let relativePath = normalizedRelativePath(for: url, sourceRoot: sourceRoot)
            guard !relativePath.isEmpty else { continue }
            let item = try buildItem(for: url, relativePath: relativePath, transferPolicy: transferPolicy)
            guard let item else { continue }
            items.append(item)
            if let onItem {
                await onItem(item)
            }
            try await checkpoint(pauseController)
        }
        return items
    }

    func scanSubtree(
        sourceRoot: URL,
        anchorRelativePath: String,
        transferPolicy: TransferPolicy,
        pauseController: PauseController? = nil,
        onItem: (@Sendable (ScannedItem) async -> Void)? = nil
    ) async throws -> [ScannedItem] {
        let subtreeURL = sourceRoot.appendingPathComponent(anchorRelativePath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: subtreeURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw PipelineError.copyFailed(subtreeURL.path)
        }

        var items: [ScannedItem] = []
        while let url = enumerator.nextObject() as? URL {
            try await checkpoint(pauseController)
            let relativePath = normalizedRelativePath(for: url, sourceRoot: sourceRoot)
            guard !relativePath.isEmpty, relativePath != anchorRelativePath else { continue }
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
            let item = makeItem(url: url, relativePath: relativePath, values: values, kind: kind)
            items.append(item)
            if let onItem {
                await onItem(item)
            }
            try await checkpoint(pauseController)
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    func scan(
        sourceRoot: URL,
        transferPolicy: TransferPolicy,
        pauseController: PauseController? = nil,
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
            try await checkpoint(pauseController)
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
            let item = makeItem(url: url, relativePath: relativePath, values: values, kind: kind)
            items.append(item)
            if let onItem {
                await onItem(item)
            }
            try await checkpoint(pauseController)
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
            hydrationState: localReady ? .ready : .notRequested,
            hydrationError: nil,
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

    private func checkpoint(_ pauseController: PauseController?) async throws {
        try Task.checkCancellation()
        if let pauseController {
            try await pauseController.checkpoint()
        }
        try Task.checkCancellation()
    }

    private func buildItem(
        for url: URL,
        relativePath: String,
        transferPolicy: TransferPolicy
    ) throws -> ScannedItem? {
        let values = try url.resourceValues(forKeys: resourceKeys)
        let isDirectory = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let kind: ItemKind = isSymlink ? .symlink : (isDirectory ? .directory : .file)
        switch transferPolicy.scanDecision(relativePath: relativePath, kind: kind) {
        case .include:
            return makeItem(url: url, relativePath: relativePath, values: values, kind: kind)
        case .excludeItem, .excludeDescendants:
            return nil
        }
    }

    private func makeItem(
        url: URL,
        relativePath: String,
        values: URLResourceValues,
        kind: ItemKind
    ) -> ScannedItem {
        let isUbiquitous = values.isUbiquitousItem ?? false
        let downloadStatus = values.ubiquitousItemDownloadingStatus
        let isLocalReady = Self.isLocallyAvailable(isUbiquitous: isUbiquitous, downloadStatus: downloadStatus)
        let symlinkDestination: String?
        if kind == .symlink {
            symlinkDestination = try? fileManager.destinationOfSymbolicLink(atPath: url.path)
        } else {
            symlinkDestination = nil
        }
        return ScannedItem(
            id: UUID(),
            relativePath: relativePath,
            kind: kind,
            expectedSize: Int64(values.fileSize ?? 0),
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            isUbiquitous: isUbiquitous,
            isLocalReady: isLocalReady,
            downloadStatusRaw: downloadStatus?.rawValue,
            symlinkDestination: symlinkDestination,
            hydrationState: isLocalReady ? .ready : .notRequested,
            hydrationError: nil,
            state: isLocalReady ? .localReady : .pending,
            lastError: nil
        )
    }
}
