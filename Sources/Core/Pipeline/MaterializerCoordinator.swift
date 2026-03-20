import Foundation

actor MaterializerCoordinator {
    private let scanEngine = ScanEngine()
    private let chunkPlanner = ChunkPlanner()
    private let downloadEngine = DownloadEngine()
    private let copyEngine = CopyEngine()
    private let verificationEngine = VerificationEngine()
    private let promotionEngine = PromotionEngine()
    private let finderRecoveryEngine = FinderRecoveryEngine()
    private let zipEngine = ZipEngine()
    private let logger = AppLogger()

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

        var snapshot = initialSnapshot(configuration: configuration)
        var failures: [FailureRecord] = []

        do {
            let workingDirectories = try await promotionEngine.prepare(configuration: configuration)
            try await promotionEngine.quarantineExistingVisibleTargetIfNeeded(
                configuration: configuration,
                quarantineRoot: workingDirectories.quarantineRoot
            )

            snapshot.phase = .scanning
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            await log(.info, "Scanning source tree", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: configuration.sourceURL.path)
            let items = try await scanEngine.scan(sourceRoot: configuration.sourceURL)
            snapshot.totalDiscovered = items.count
            snapshot.estimatedRemainingCount = items.count
            try await store.saveItems(jobID: configuration.jobID, items: items)

            snapshot.phase = .planningChunks
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            let chunks = chunkPlanner.plan(items: items)
            try await store.saveChunks(jobID: configuration.jobID, chunks: chunks)
            await log(.info, "Planned \(chunks.count) chunks", jobID: configuration.jobID, store: store, onUpdate: onUpdate)

            let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })
            let outcomes = try await processChunks(
                chunks: chunks,
                itemMap: itemMap,
                configuration: configuration,
                workingDirectories: workingDirectories,
                pauseController: pauseController,
                store: store,
                onUpdate: onUpdate
            )
            failures.append(contentsOf: outcomes.flatMap(\.failures))
            snapshot.totalDownloaded = outcomes.reduce(0) { $0 + $1.downloadedCount }
            snapshot.totalCopied = outcomes.reduce(0) { $0 + $1.copiedCount }
            snapshot.totalFailed = failures.count
            snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
            snapshot.throughputItemsPerSecond = throughput(from: snapshot)
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            if !failures.isEmpty {
                snapshot.phase = .failed
                snapshot.finishedAt = Date()
                snapshot.lastError = failures.first?.message
                try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
                await onUpdate(.failures(failures))
                return
            }

            snapshot.phase = .finalVerifying
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            _ = try await verificationEngine.verify(expectedItems: items, at: workingDirectories.assembledRoot)

            snapshot.phase = .promoting
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            try await promotionEngine.promoteFinal(
                from: workingDirectories.assembledRoot,
                to: configuration.visibleTargetURL
            )

            snapshot.phase = .zipping
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            do {
                let zipURL = try await zipEngine.archiveSource(
                    sourceRoot: configuration.sourceURL,
                    expectedItems: items,
                    archiveRoot: workingDirectories.archiveRoot,
                    configuration: configuration,
                    downloadEngine: downloadEngine,
                    pauseController: pauseController,
                    onProgress: { [weak self] path in
                        await self?.log(.info, "Preparing ZIP input \(path)", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: path)
                    }
                )
                await log(.info, "Created ZIP at \(zipURL.path)", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: zipURL.path)
                snapshot.phase = .completed
            } catch {
                snapshot.phase = .completedWithWarnings
                snapshot.lastError = error.localizedDescription
                await log(.warning, "ZIP phase finished with warning: \(error.localizedDescription)", jobID: configuration.jobID, store: store, onUpdate: onUpdate)
            }

            snapshot.finishedAt = Date()
            snapshot.estimatedRemainingCount = 0
            snapshot.throughputItemsPerSecond = throughput(from: snapshot)
            try await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            if !failures.isEmpty {
                await onUpdate(.failures(failures))
            }
        } catch is CancellationError {
            snapshot.phase = .cancelled
            snapshot.finishedAt = Date()
            snapshot.lastError = "Job cancelled."
            try? await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
        } catch {
            let failure = FailureRecord(
                id: UUID(),
                relativePath: snapshot.currentPath ?? configuration.sourceURL.path,
                reason: .copy,
                message: error.localizedDescription,
                recoveryMode: .direct,
                createdAt: Date()
            )
            failures.append(failure)
            try? await store.saveFailure(jobID: configuration.jobID, failure: failure)
            snapshot.phase = .failed
            snapshot.finishedAt = Date()
            snapshot.totalFailed = failures.count
            snapshot.lastError = error.localizedDescription
            try? await publish(snapshot: snapshot, store: store, onUpdate: onUpdate)
            await onUpdate(.failures(failures))
        }
    }

    private func processChunks(
        chunks: [ChunkManifest],
        itemMap: [String: ScannedItem],
        configuration: JobConfiguration,
        workingDirectories: WorkingDirectories,
        pauseController: PauseController,
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
                        workingDirectories: workingDirectories,
                        pauseController: pauseController,
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
                            workingDirectories: workingDirectories,
                            pauseController: pauseController,
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
        workingDirectories: WorkingDirectories,
        pauseController: PauseController,
        store: JobStore,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async throws -> ChunkOutcome {
        let items = chunk.relativePaths.compactMap { itemMap[$0] }
        let stageRoot = workingDirectories.stagingRoot.appendingPathComponent(chunk.id.uuidString, isDirectory: true)
        await log(.info, "Processing chunk \(chunk.id.uuidString)", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: chunk.anchorRelativePath)

        do {
            let report = try await downloadEngine.materialize(
                items: items,
                sourceRoot: configuration.sourceURL,
                configuration: configuration,
                pauseController: pauseController,
                onProgress: { [weak self] path in
                    await self?.log(.info, "Materializing \(path)", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: path)
                }
            )
            try await store.saveItems(jobID: configuration.jobID, items: report.items)
            try await copyEngine.copyChunk(
                items: report.items,
                sourceRoot: configuration.sourceURL,
                stageRoot: stageRoot,
                pauseController: pauseController,
                onProgress: { [weak self] path in
                    await self?.log(.info, "Copying \(path)", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: path)
                }
            )
            _ = try await verificationEngine.verify(expectedItems: report.items, at: stageRoot)
            try await promotionEngine.promoteChunk(from: stageRoot, into: workingDirectories.assembledRoot)
            return ChunkOutcome(
                chunkID: chunk.id,
                copiedCount: report.items.count,
                downloadedCount: report.downloadedCount,
                recoveryMode: .direct,
                failures: []
            )
        } catch {
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
                return ChunkOutcome(
                    chunkID: chunk.id,
                    copiedCount: 0,
                    downloadedCount: 0,
                    recoveryMode: .direct,
                    failures: [failure]
                )
            }

            await log(.warning, "Direct path failed; switching chunk to Finder recovery", jobID: configuration.jobID, store: store, onUpdate: onUpdate, path: chunk.anchorRelativePath)
            do {
                try await finderRecoveryEngine.recoverChunk(
                    chunk: chunk,
                    sourceRoot: configuration.sourceURL,
                    stageRoot: stageRoot
                )
                _ = try await verificationEngine.verify(expectedItems: items, at: stageRoot)
                try await promotionEngine.promoteChunk(from: stageRoot, into: workingDirectories.assembledRoot)
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
            sourcePath: configuration.sourceURL.path,
            destinationPath: configuration.destinationURL.path,
            currentPath: nil,
            totalDiscovered: 0,
            totalDownloaded: 0,
            totalCopied: 0,
            totalFailed: 0,
            estimatedRemainingCount: 0,
            throughputItemsPerSecond: 0,
            startedAt: Date(),
            finishedAt: nil,
            lastError: nil
        )
    }

    private func throughput(from snapshot: JobSnapshot) -> Double {
        guard let startedAt = snapshot.startedAt else { return 0 }
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        return Double(snapshot.totalCopied) / elapsed
    }

    private func publish(snapshot: JobSnapshot, store: JobStore, onUpdate: @escaping @Sendable (JobUpdate) async -> Void) async throws {
        try await store.saveJobSnapshot(snapshot)
        await onUpdate(.snapshot(snapshot))
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
        failureSnapshot.finishedAt = Date()
        failureSnapshot.lastError = error.localizedDescription
        await onUpdate(.snapshot(failureSnapshot))
    }
}
