import Foundation

struct HydrationPrimingCandidate: Sendable, Hashable {
    var url: URL
    var relativePath: String
}

struct HydrationPrimingReport: Sendable, Equatable {
    var requestedCount: Int = 0
    var readPressureDirectoryCount: Int = 0
    var readPressureFileCount: Int = 0
    var readPressureFailureCount: Int = 0
    var readPressureTimeoutCount: Int = 0

    var didWork: Bool {
        requestedCount > 0 ||
        readPressureDirectoryCount > 0 ||
        readPressureFileCount > 0 ||
        readPressureFailureCount > 0 ||
        readPressureTimeoutCount > 0
    }
}

struct HydrationPrimer: Sendable {
    private struct ProbeOutcome: Sendable {
        var directoryCount: Int = 0
        var fileCount: Int = 0
        var failureCount: Int = 0
        var timeoutCount: Int = 0
    }

    static func primeProject(
        projectURL: URL,
        transferPolicy: TransferPolicy,
        scanDepth: Int,
        hydrationMode: HydrationMode,
        readPressureConcurrency: Int,
        pauseController: PauseController? = nil
    ) async throws -> HydrationPrimingReport {
        let childLimit = recommendedCandidateLimit(
            scanDepth: scanDepth,
            hydrationMode: hydrationMode
        )
        let urls = BatchCoordinator.prefetchCandidateURLs(
            projectURL: projectURL,
            transferPolicy: transferPolicy,
            childLimit: childLimit
        )
        let candidates = urls.map { url in
            HydrationPrimingCandidate(
                url: url,
                relativePath: normalizedRelativePath(for: url, rootURL: projectURL)
            )
        }
        return try await prime(
            candidates: candidates,
            hydrationMode: hydrationMode,
            readPressureConcurrency: readPressureConcurrency,
            pauseController: pauseController
        )
    }

    static func prime(
        candidates: [HydrationPrimingCandidate],
        hydrationMode: HydrationMode,
        readPressureConcurrency: Int,
        readPressureProbeTimeout: Duration? = nil,
        pauseController: PauseController? = nil
    ) async throws -> HydrationPrimingReport {
        let uniqueCandidates = uniqued(candidates)
        guard !uniqueCandidates.isEmpty else { return HydrationPrimingReport() }

        var report = HydrationPrimingReport()
        let probeTimeout = readPressureProbeTimeout ?? defaultReadPressureProbeTimeout(for: hydrationMode)

        if hydrationMode.usesAPIRequests {
            report.requestedCount = try await requestDownloads(
                for: uniqueCandidates,
                pauseController: pauseController
            )
        }

        if hydrationMode.usesReadPressure {
            let probeReport = try await applyReadPressure(
                to: uniqueCandidates,
                concurrency: readPressureConcurrency,
                probeTimeout: probeTimeout,
                pauseController: pauseController
            )
            report.readPressureDirectoryCount = probeReport.directoryCount
            report.readPressureFileCount = probeReport.fileCount
            report.readPressureFailureCount = probeReport.failureCount
            report.readPressureTimeoutCount = probeReport.timeoutCount
        }

        return report
    }

    private static func requestDownloads(
        for candidates: [HydrationPrimingCandidate],
        pauseController: PauseController?
    ) async throws -> Int {
        let resourceKeys: Set<URLResourceKey> = [.isUbiquitousItemKey]
        var requestedCount = 0

        for candidate in candidates {
            try await checkpoint(pauseController)
            guard let values = try? candidate.url.resourceValues(forKeys: resourceKeys),
                  values.isUbiquitousItem == true else {
                continue
            }
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: candidate.url)
                requestedCount += 1
            } catch {
                continue
            }
        }

        return requestedCount
    }

    private static func applyReadPressure(
        to candidates: [HydrationPrimingCandidate],
        concurrency: Int,
        probeTimeout: Duration,
        pauseController: PauseController?
    ) async throws -> ProbeOutcome {
        guard !candidates.isEmpty else { return ProbeOutcome() }
        let maxConcurrency = min(max(concurrency, 1), candidates.count)
        var iterator = candidates.makeIterator()
        var aggregate = ProbeOutcome()

        try await withThrowingTaskGroup(of: ProbeOutcome.self) { group in
            for _ in 0..<maxConcurrency {
                guard let candidate = iterator.next() else { break }
                group.addTask {
                    try await checkpoint(pauseController)
                    return await probe(candidate, timeout: probeTimeout)
                }
            }

            while let outcome = try await group.next() {
                aggregate.directoryCount += outcome.directoryCount
                aggregate.fileCount += outcome.fileCount
                aggregate.failureCount += outcome.failureCount
                aggregate.timeoutCount += outcome.timeoutCount

                guard let candidate = iterator.next() else { continue }
                group.addTask {
                    try await checkpoint(pauseController)
                    return await probe(candidate, timeout: probeTimeout)
                }
            }
        }

        return aggregate
    }

    private static func probe(
        _ candidate: HydrationPrimingCandidate,
        timeout: Duration
    ) async -> ProbeOutcome {
        let sanitizedTimeout = max(timeout.timeInterval, 0.05)
        let probeTask = Task.detached(priority: .utility) {
            probeSynchronously(candidate)
        }

        return await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask {
                await probeTask.value
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(sanitizedTimeout * 1_000_000_000))
                } catch {
                    return ProbeOutcome()
                }
                probeTask.cancel()
                return ProbeOutcome(timeoutCount: 1)
            }

            let outcome = await group.next() ?? ProbeOutcome()
            group.cancelAll()
            return outcome
        }
    }

    private static func probeSynchronously(_ candidate: HydrationPrimingCandidate) -> ProbeOutcome {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]
        let isDirectory = (try? candidate.url.resourceValues(forKeys: resourceKeys))?.isDirectory == true

        if isDirectory {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: candidate.url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsPackageDescendants]
                )
                return ProbeOutcome(directoryCount: 1, fileCount: 0, failureCount: 0)
            } catch {
                return ProbeOutcome(directoryCount: 0, fileCount: 0, failureCount: 1)
            }
        }

        do {
            let handle = try FileHandle(forReadingFrom: candidate.url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return ProbeOutcome(directoryCount: 0, fileCount: 1, failureCount: 0)
        } catch {
            return ProbeOutcome(directoryCount: 0, fileCount: 0, failureCount: 1)
        }
    }

    private static func checkpoint(_ pauseController: PauseController?) async throws {
        try Task.checkCancellation()
        if let pauseController {
            try await pauseController.checkpoint()
        }
        try Task.checkCancellation()
    }

    private static func uniqued(_ candidates: [HydrationPrimingCandidate]) -> [HydrationPrimingCandidate] {
        var seen: Set<String> = []
        var unique: [HydrationPrimingCandidate] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            let key = candidate.url.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            unique.append(candidate)
        }

        return unique
    }

    private static func normalizedRelativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        if candidatePath == rootPath {
            return rootURL.lastPathComponent
        }
        return candidatePath.replacingOccurrences(of: "\(rootPath)/", with: "")
    }

    private static func recommendedCandidateLimit(
        scanDepth: Int,
        hydrationMode: HydrationMode
    ) -> Int {
        let baseLimit = BatchCoordinator.prefetchCandidateLimit(scanDepth: scanDepth)
        let ceiling = hydrationMode.usesReadPressure ? 48 : 128
        return min(baseLimit, ceiling)
    }

    private static func defaultReadPressureProbeTimeout(for hydrationMode: HydrationMode) -> Duration {
        switch hydrationMode {
        case .apiOnly:
            return .milliseconds(250)
        case .hybridReadPressure:
            return .milliseconds(400)
        case .readPressureOnly:
            return .milliseconds(600)
        }
    }
}
