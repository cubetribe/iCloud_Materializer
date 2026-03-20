import Foundation

final class MaterializerCoordinator: @unchecked Sendable {
    private let scanEngine = ScanEngine()
    private let chunkPlanner = ChunkPlanner()
    private let downloadEngine = DownloadEngine()
    private let copyEngine = CopyEngine()
    private let verificationEngine = VerificationEngine()
    private let promotionEngine = PromotionEngine()
    private let finderRecoveryEngine = FinderRecoveryEngine()
    private let zipEngine = ZipEngine()
    private let logger = AppLogger()
    private let postPromotionHook: (@Sendable (URL) async throws -> Void)?

    init(
        postPromotionHook: (@Sendable (URL) async throws -> Void)? = nil
    ) {
        self.postPromotionHook = postPromotionHook
    }

    func run(
        configuration: JobConfiguration,
        pauseController: PauseController,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async {
        let store: JobStore
        do {
            store = try JobStore(databaseURL: configuration.databaseURL)
        } catch {
            await emitFatal(snapshot: initialSnapshot(configuration: configuration), error: error, onUpdate: onUpdate)
            return
        }
        defer {
            Task {
                try? await store.close()
            }
        }

        let tracker = ProgressTracker(
            snapshot: initialSnapshot(configuration: configuration),
            store: store,
            onUpdate: onUpdate
        )
        var failures: [FailureRecord] = []

        do {
            try validateDestinationLayout(configuration: configuration)
            let workingDirectories = try await promotionEngine.prepare(configuration: configuration)
            try await promotionEngine.quarantineExistingVisibleTargetIfNeeded(
                configuration: configuration,
                quarantineRoot: workingDirectories.quarantineRoot
            )

            try await tracker.begin(
                detail: "Scanning source tree",
                path: configuration.sourceURL.path
            )
            await log(
                .info,
                configuration.transferPolicy.runtimeSummary,
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate
            )
            await log(
                .info,
                configuration.priorityPolicy.runtimeSummary,
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate
            )
            await log(
                .info,
                "Hydration window: \(configuration.hydrationWindow) active iCloud items per worker, lookahead buffer \(configuration.effectiveHydrationPrefetchBuffer) overall, up to \(configuration.maxActiveHydrations) active / \(configuration.maxRequestedHydrations) requested overall",
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate
            )
            for warning in configuration.transferPolicy.ignoredCustomRules {
                await log(
                    .warning,
                    warning,
                    jobID: configuration.jobID,
                    store: store,
                    onUpdate: onUpdate
                )
            }
            await log(
                .info,
                "Scanning source tree",
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate,
                path: configuration.sourceURL.path
            )

            let items = try await scanEngine.scan(
                sourceRoot: configuration.sourceURL,
                transferPolicy: configuration.transferPolicy
            ) { item in
                try? await tracker.scanned(item)
            }
            try await store.saveItems(jobID: configuration.jobID, items: items)
            if let prioritySummary = configuration.priorityPolicy.inventorySummary(for: items) {
                await log(
                    .info,
                    "Priority inventory: \(prioritySummary)",
                    jobID: configuration.jobID,
                    store: store,
                    onUpdate: onUpdate
                )
            }

            try await tracker.updateTopLevelPhase(
                .planningChunks,
                detail: "Planning chunks",
                force: true
            )
            let chunks = chunkPlanner.plan(items: items, priorityPolicy: configuration.priorityPolicy)
            try await store.saveChunks(jobID: configuration.jobID, chunks: chunks)
            try await tracker.planned(chunkCount: chunks.count)
            await log(
                .info,
                "Planned \(chunks.count) chunks",
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate
            )

            let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })
            let hydrationSession = HydrationSession(maxRequestedHydrations: configuration.maxRequestedHydrations)
            let outcomes = try await processChunks(
                chunks: chunks,
                itemMap: itemMap,
                configuration: configuration,
                hydrationSession: hydrationSession,
                workingDirectories: workingDirectories,
                pauseController: pauseController,
                tracker: tracker,
                store: store,
                onUpdate: onUpdate
            )
            failures.append(contentsOf: outcomes.flatMap(\.failures))

            if !failures.isEmpty {
                try await tracker.fail(message: failures.first?.message ?? "One or more chunks failed.")
                await onUpdate(.failures(failures))
                return
            }

            let assembledVerification = try await verifyTree(
                expectedItems: items,
                at: workingDirectories.assembledRoot,
                detail: "Verifying assembled target",
                tracker: tracker
            )
            await log(
                .info,
                "Verified assembled target: \(assembledVerification.verifiedCount) items, \(assembledVerification.verifiedBytes) bytes",
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate,
                path: workingDirectories.assembledRoot.path
            )

            try await tracker.updateTopLevelPhase(
                .promoting,
                detail: "Promoting assembled tree into destination",
                path: configuration.visibleTargetURL.path,
                force: true
            )
            try await promotionEngine.promoteFinal(
                from: workingDirectories.assembledRoot,
                to: configuration.visibleTargetURL
            )
            if let postPromotionHook {
                try await postPromotionHook(configuration.visibleTargetURL)
            }

            let visibleTargetVerification = try await verifyTree(
                expectedItems: items,
                at: configuration.visibleTargetURL,
                detail: "Verifying visible target",
                tracker: tracker
            )
            await log(
                .info,
                "Verified visible target: \(visibleTargetVerification.verifiedCount) items, \(visibleTargetVerification.verifiedBytes) bytes",
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate,
                path: configuration.visibleTargetURL.path
            )

            try await tracker.updateTopLevelPhase(
                .zipping,
                detail: "Creating source ZIP archive",
                path: configuration.sourceURL.path,
                force: true
            )
            do {
                let zipURL = try await zipEngine.archiveSource(
                    sourceRoot: configuration.sourceURL,
                    expectedItems: items,
                    archiveRoot: workingDirectories.archiveRoot,
                    configuration: configuration,
                    downloadEngine: downloadEngine,
                    hydrationSession: hydrationSession,
                    pauseController: pauseController,
                    onProgress: { path in
                        try? await tracker.updateTopLevelPhase(
                            .zipping,
                            detail: "Preparing source data for ZIP",
                            path: path,
                            force: false
                        )
                    }
                )
                await log(
                    .info,
                    "Created ZIP at \(zipURL.path)",
                    jobID: configuration.jobID,
                    store: store,
                    onUpdate: onUpdate,
                    path: zipURL.path
                )
                try await tracker.complete(phase: .completed)
            } catch {
                await log(
                    .warning,
                    "ZIP phase finished with warning: \(error.localizedDescription)",
                    jobID: configuration.jobID,
                    store: store,
                    onUpdate: onUpdate
                )
                try await tracker.complete(phase: .completedWithWarnings, lastError: error.localizedDescription)
            }

            if !failures.isEmpty {
                await onUpdate(.failures(failures))
            }
        } catch is CancellationError {
            try? await tracker.cancel(message: "Job cancelled.")
        } catch {
            let failure = FailureRecord(
                id: UUID(),
                relativePath: configuration.sourceURL.path,
                reason: .copy,
                message: error.localizedDescription,
                recoveryMode: .direct,
                createdAt: Date()
            )
            failures.append(failure)
            try? await store.saveFailure(jobID: configuration.jobID, failure: failure)
            try? await tracker.markFailure(failure)
            try? await tracker.fail(message: error.localizedDescription)
            await onUpdate(.failures(failures))
        }
    }

    private func processChunks(
        chunks: [ChunkManifest],
        itemMap: [String: ScannedItem],
        configuration: JobConfiguration,
        hydrationSession: HydrationSession,
        workingDirectories: WorkingDirectories,
        pauseController: PauseController,
        tracker: ProgressTracker,
        store: JobStore,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async throws -> [ChunkOutcome] {
        guard !chunks.isEmpty else { return [] }

        var outcomes: [ChunkOutcome] = []
        var iterator = chunks.makeIterator()
        let initialCount = min(configuration.workerCount, chunks.count)

        try await withThrowingTaskGroup(of: ChunkOutcome.self) { group in
            for _ in 0 ..< initialCount {
                guard let chunk = iterator.next() else { break }
                group.addTask { [self] in
                    try await self.processChunk(
                        chunk: chunk,
                        itemMap: itemMap,
                        configuration: configuration,
                        hydrationSession: hydrationSession,
                        workingDirectories: workingDirectories,
                        pauseController: pauseController,
                        tracker: tracker,
                        store: store,
                        onUpdate: onUpdate
                    )
                }
            }

            while let outcome = try await group.next() {
                outcomes.append(outcome)
                if let nextChunk = iterator.next() {
                    group.addTask { [self] in
                        try await self.processChunk(
                            chunk: nextChunk,
                            itemMap: itemMap,
                            configuration: configuration,
                            hydrationSession: hydrationSession,
                            workingDirectories: workingDirectories,
                            pauseController: pauseController,
                            tracker: tracker,
                            store: store,
                            onUpdate: onUpdate
                        )
                    }
                }
            }
        }

        return outcomes
    }

    private func processChunk(
        chunk: ChunkManifest,
        itemMap: [String: ScannedItem],
        configuration: JobConfiguration,
        hydrationSession: HydrationSession,
        workingDirectories: WorkingDirectories,
        pauseController: PauseController,
        tracker: ProgressTracker,
        store: JobStore,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async throws -> ChunkOutcome {
        let items = chunk.relativePaths.compactMap { itemMap[$0] }
        let stageRoot = workingDirectories.stagingRoot.appendingPathComponent(chunk.id.uuidString, isDirectory: true)
        let workerLabel = chunkLabel(for: chunk)

        await log(
            .info,
            "Processing \(workerLabel)",
            jobID: configuration.jobID,
            store: store,
            onUpdate: onUpdate,
            path: chunk.anchorRelativePath
        )

        let copyTally = ChunkCopyTally()

        do {
            try await tracker.updateWorker(
                id: chunk.id,
                label: workerLabel,
                phase: .materializing,
                detail: "Materializing iCloud content",
                path: chunk.anchorRelativePath ?? chunk.relativePaths.first
            )
            let report = try await downloadEngine.materialize(
                items: items,
                sourceRoot: configuration.sourceURL,
                configuration: configuration,
                pauseController: pauseController,
                hydrationSession: hydrationSession,
                onEvent: { event in
                    switch event {
                    case .evaluating(let item):
                        let detail = item.isUbiquitous && !item.isLocalReady ? "Downloading from iCloud" : "Checking local availability"
                        try? await tracker.updateWorker(
                            id: chunk.id,
                            label: workerLabel,
                            phase: .materializing,
                            detail: detail,
                            path: item.relativePath
                        )
                    case .deferred(let item, let retryAfter):
                        let retrySeconds = Int(retryAfter.timeInterval.rounded(.up))
                        try? await tracker.updateWorker(
                            id: chunk.id,
                            label: workerLabel,
                            phase: .materializing,
                            detail: "Cooling slow iCloud item, retrying in \(retrySeconds)s",
                            path: item.relativePath
                        )
                    case .ready(let item, let downloaded):
                        try? await tracker.markDownloadReady(item: item, downloaded: downloaded)
                    }
                }
            )
            try await store.saveItems(jobID: configuration.jobID, items: report.items)

            try await tracker.updateWorker(
                id: chunk.id,
                label: workerLabel,
                phase: .copying,
                detail: "Copying into staging",
                path: chunk.anchorRelativePath ?? chunk.relativePaths.first
            )
            try await copyEngine.copyChunk(
                items: report.items,
                sourceRoot: configuration.sourceURL,
                stageRoot: stageRoot,
                priorityPolicy: configuration.priorityPolicy,
                pauseController: pauseController,
                onEvent: { event in
                    switch event {
                    case .preparing(let item):
                        try? await tracker.updateWorker(
                            id: chunk.id,
                            label: workerLabel,
                            phase: .copying,
                            detail: "Copying into staging",
                            path: item.relativePath
                        )
                    case .copied(let item):
                        await copyTally.record(item)
                        try? await tracker.markCopied(item: item)
                    }
                }
            )

            try await tracker.updateWorker(
                id: chunk.id,
                label: workerLabel,
                phase: .verifying,
                detail: "Verifying staged chunk",
                path: chunk.anchorRelativePath ?? chunk.relativePaths.first
            )
            _ = try await verificationEngine.verify(expectedItems: report.items, at: stageRoot) { path in
                try? await tracker.updateWorker(
                    id: chunk.id,
                    label: workerLabel,
                    phase: .verifying,
                    detail: "Verifying staged chunk",
                    path: path
                )
            }

            try await tracker.updateWorker(
                id: chunk.id,
                label: workerLabel,
                phase: .promoting,
                detail: "Promoting verified chunk",
                path: chunk.anchorRelativePath ?? chunk.relativePaths.first
            )
            try await promotionEngine.promoteChunk(from: stageRoot, into: workingDirectories.assembledRoot)
            try await tracker.markChunkFinished()
            try await tracker.clearWorker(id: chunk.id)

            return ChunkOutcome(
                chunkID: chunk.id,
                copiedCount: report.items.count,
                downloadedCount: report.downloadedCount,
                recoveryMode: .direct,
                failures: []
            )
        } catch {
            let stagedTally = await copyTally.snapshot()
            if stagedTally.count > 0 || stagedTally.bytes > 0 {
                try? await tracker.rollbackCopied(itemCount: stagedTally.count, bytes: stagedTally.bytes)
            }

            guard configuration.enableFinderFallback else {
                let failure = FailureRecord(
                    id: UUID(),
                    relativePath: chunk.anchorRelativePath ?? chunk.relativePaths.first ?? "<unknown>",
                    reason: .copy,
                    message: error.localizedDescription,
                    recoveryMode: .direct,
                    createdAt: Date()
                )
                try await store.saveFailure(jobID: configuration.jobID, failure: failure)
                try? await tracker.markFailure(failure)
                try? await tracker.clearWorker(id: chunk.id)
                return ChunkOutcome(
                    chunkID: chunk.id,
                    copiedCount: 0,
                    downloadedCount: 0,
                    recoveryMode: .direct,
                    failures: [failure]
                )
            }

            await log(
                .warning,
                "Direct copy failed; switching \(workerLabel) to recovery copy",
                jobID: configuration.jobID,
                store: store,
                onUpdate: onUpdate,
                path: chunk.anchorRelativePath
            )

            do {
                try await tracker.updateWorker(
                    id: chunk.id,
                    label: workerLabel,
                    phase: .copying,
                    detail: "Recovery copy",
                    path: chunk.anchorRelativePath ?? chunk.relativePaths.first
                )
                try await finderRecoveryEngine.recoverChunk(
                    items: items,
                    sourceRoot: configuration.sourceURL,
                    stageRoot: stageRoot,
                    pauseController: pauseController
                )
                try await tracker.updateWorker(
                    id: chunk.id,
                    label: workerLabel,
                    phase: .verifying,
                    detail: "Verifying recovery copy result",
                    path: chunk.anchorRelativePath ?? chunk.relativePaths.first
                )
                _ = try await verificationEngine.verify(expectedItems: items, at: stageRoot) { path in
                    try? await tracker.updateWorker(
                        id: chunk.id,
                        label: workerLabel,
                        phase: .verifying,
                        detail: "Verifying recovery copy result",
                        path: path
                    )
                }
                try await tracker.updateWorker(
                    id: chunk.id,
                    label: workerLabel,
                    phase: .promoting,
                    detail: "Promoting recovery copy result",
                    path: chunk.anchorRelativePath ?? chunk.relativePaths.first
                )
                try await promotionEngine.promoteChunk(from: stageRoot, into: workingDirectories.assembledRoot)
                for item in items {
                    try? await tracker.markCopied(item: item)
                }
                try await tracker.markChunkFinished()
                try await tracker.clearWorker(id: chunk.id)
                return ChunkOutcome(
                    chunkID: chunk.id,
                    copiedCount: items.count,
                    downloadedCount: 0,
                    recoveryMode: .finder,
                    failures: []
                )
            } catch {
                let failure = FailureRecord(
                    id: UUID(),
                    relativePath: chunk.anchorRelativePath ?? chunk.relativePaths.first ?? "<unknown>",
                    reason: .finderRecovery,
                    message: error.localizedDescription,
                    recoveryMode: .finder,
                    createdAt: Date()
                )
                try await store.saveFailure(jobID: configuration.jobID, failure: failure)
                try? await tracker.markFailure(failure)
                try? await tracker.clearWorker(id: chunk.id)
                return ChunkOutcome(
                    chunkID: chunk.id,
                    copiedCount: 0,
                    downloadedCount: 0,
                    recoveryMode: .finder,
                    failures: [failure]
                )
            }
        }
    }

    private func initialSnapshot(configuration: JobConfiguration) -> JobSnapshot {
        JobSnapshot(
            jobID: configuration.jobID,
            phase: .idle,
            phaseDetail: nil,
            sourcePath: configuration.sourceURL.path,
            destinationPath: configuration.destinationURL.path,
            currentPath: nil,
            totalDiscovered: 0,
            totalDownloaded: 0,
            totalCopied: 0,
            totalFailed: 0,
            plannedChunks: 0,
            processedChunks: 0,
            estimatedRemainingCount: 0,
            throughputItemsPerSecond: 0,
            throughputBytesPerSecond: 0,
            totalExpectedBytes: 0,
            copiedBytes: 0,
            activeWorkerCount: 0,
            estimatedRemainingSeconds: nil,
            startedAt: Date(),
            finishedAt: nil,
            lastError: nil
        )
    }

    private func chunkLabel(for chunk: ChunkManifest) -> String {
        if let anchor = chunk.anchorRelativePath, !anchor.isEmpty {
            return anchor
        }
        if let first = chunk.relativePaths.first {
            return first
        }
        return "chunk-\(chunk.id.uuidString.prefix(8))"
    }

    private func validateDestinationLayout(configuration: JobConfiguration) throws {
        let sourcePath = configuration.sourceURL.standardizedFileURL.path
        let destinationPath = configuration.destinationURL.standardizedFileURL.path
        let visibleTargetPath = configuration.visibleTargetURL.standardizedFileURL.path

        if sourcePath == destinationPath {
            throw PipelineError.invalidDestination("Destination folder must not be the same as the source folder.")
        }
        if visibleTargetPath == sourcePath {
            throw PipelineError.invalidDestination("Destination folder would place the copied project on top of the source folder.")
        }
        if destinationPath.hasPrefix(sourcePath + "/") {
            throw PipelineError.invalidDestination("Destination folder must not be inside the source folder.")
        }
    }

    private func verifyTree(
        expectedItems: [ScannedItem],
        at root: URL,
        detail: String,
        tracker: ProgressTracker
    ) async throws -> VerificationResult {
        try await tracker.updateTopLevelPhase(
            .finalVerifying,
            detail: detail,
            path: root.path,
            force: true
        )
        return try await verificationEngine.verify(expectedItems: expectedItems, at: root) { path in
            try? await tracker.updateTopLevelPhase(
                .finalVerifying,
                detail: detail,
                path: path,
                force: false
            )
        }
    }

    private func log(
        _ level: LogLevel,
        _ message: String,
        jobID: UUID,
        store: JobStore,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void,
        path: String? = nil
    ) async {
        let entry = await logger.append(level: level, message: message, path: path)
        try? await store.appendEvent(jobID: jobID, entry: entry)
        await onUpdate(.log(entry))
    }

    private func emitFatal(
        snapshot: JobSnapshot,
        error: Error,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async {
        var failureSnapshot = snapshot
        failureSnapshot.phase = .failed
        failureSnapshot.phaseDetail = "Failed before job startup"
        failureSnapshot.finishedAt = Date()
        failureSnapshot.lastError = error.localizedDescription
        await onUpdate(.snapshot(failureSnapshot))
    }
}

private actor ChunkCopyTally {
    private var count = 0
    private var bytes: Int64 = 0

    func record(_ item: ScannedItem) {
        count += 1
        if item.kind == .file {
            bytes += item.expectedSize
        }
    }

    func snapshot() -> (count: Int, bytes: Int64) {
        (count, bytes)
    }
}
