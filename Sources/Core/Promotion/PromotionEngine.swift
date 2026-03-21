import Foundation

actor PromotionEngine {
    private let fileManager = FileManager.default

    func prepare(configuration: JobConfiguration) throws -> WorkingDirectories {
        let root = configuration.workingRootURL
        let assembledContainerRoot = root.appendingPathComponent("assembled", isDirectory: true)
        let directories = WorkingDirectories(
            root: root,
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            assembledRoot: assembledContainerRoot.appendingPathComponent(configuration.sourceURL.lastPathComponent, isDirectory: true),
            archiveRoot: root.appendingPathComponent("archive", isDirectory: true),
            quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [directories.stagingRoot, assembledContainerRoot, directories.archiveRoot] where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directories.stagingRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directories.assembledRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directories.archiveRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directories.quarantineRoot, withIntermediateDirectories: true)
        return directories
    }

    func quarantineExistingVisibleTargetIfNeeded(configuration: JobConfiguration, quarantineRoot: URL) throws {
        let visibleTarget = configuration.visibleTargetURL
        guard fileManager.fileExists(atPath: visibleTarget.path) else { return }
        guard configuration.allowTargetQuarantine else {
            throw PipelineError.promotionConflict(visibleTarget)
        }
        let quarantineURL = quarantineRoot.appendingPathComponent(visibleTarget.lastPathComponent + "-\(ISO8601DateFormatter().string(from: Date()))", isDirectory: true)
        try fileManager.moveItem(at: visibleTarget, to: quarantineURL)
    }

    func promoteChunk(from stageRoot: URL, into assembledRoot: URL, pauseController: PauseController? = nil) async throws {
        guard fileManager.fileExists(atPath: stageRoot.path) else { return }
        let subpaths = try fileManager.subpathsOfDirectory(atPath: stageRoot.path).sorted()
        for subpath in subpaths {
            try await checkpoint(pauseController)
            let sourceURL = stageRoot.appendingPathComponent(subpath)
            let destinationURL = assembledRoot.appendingPathComponent(subpath)
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw PipelineError.promotionConflict(destinationURL)
            }
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try await checkpoint(pauseController)
        }
    }

    func promoteFinal(from assembledRoot: URL, to visibleTarget: URL) throws {
        guard !fileManager.fileExists(atPath: visibleTarget.path) else {
            throw PipelineError.promotionConflict(visibleTarget)
        }
        try fileManager.moveItem(at: assembledRoot, to: visibleTarget)
    }

    private func checkpoint(_ pauseController: PauseController?) async throws {
        try Task.checkCancellation()
        if let pauseController {
            try await pauseController.checkpoint()
        }
        try Task.checkCancellation()
    }
}
