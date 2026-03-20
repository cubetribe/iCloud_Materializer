import Foundation

actor DownloadEngine {
    private let fileManager = FileManager.default

    enum Event: Sendable {
        case evaluating(ScannedItem)
        case ready(ScannedItem, downloaded: Bool)
    }

    struct Report: Sendable {
        var items: [ScannedItem]
        var downloadedCount: Int
    }

    func materialize(
        items: [ScannedItem],
        sourceRoot: URL,
        configuration: JobConfiguration,
        pauseController: PauseController,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) async throws -> Report {
        let sortedItems = configuration.priorityPolicy.sort(items: items)
        var resolvedItems: [String: ScannedItem] = [:]
        var downloadedCount = 0
        var pendingHydrations: [PendingHydration] = []

        for item in sortedItems {
            try await pauseController.checkpoint()
            guard item.isUbiquitous, !item.isLocalReady else {
                await onEvent(.evaluating(item))
                var readyItem = item
                if readyItem.state == .pending {
                    readyItem.state = .localReady
                }
                resolvedItems[readyItem.relativePath] = readyItem
                await onEvent(.ready(readyItem, downloaded: false))
                continue
            }

            let sourceURL = sourceRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            pendingHydrations.append(PendingHydration(item: item, sourceURL: sourceURL))
        }

        var nextPendingIndex = 0
        var inflight: [String: ActiveHydration] = [:]

        while nextPendingIndex < pendingHydrations.count || !inflight.isEmpty {
            try await pauseController.checkpoint()

            while inflight.count < configuration.hydrationWindow, nextPendingIndex < pendingHydrations.count {
                let pending = pendingHydrations[nextPendingIndex]
                nextPendingIndex += 1
                await onEvent(.evaluating(pending.item))
                try? fileManager.startDownloadingUbiquitousItem(at: pending.sourceURL)
                inflight[pending.item.relativePath] = ActiveHydration(
                    item: pending.item,
                    sourceURL: pending.sourceURL,
                    startedAt: Date(),
                    nextPollAt: Date(),
                    pollAttempt: 0
                )
            }

            if inflight.isEmpty {
                continue
            }

            let now = Date()
            var madeProgress = false
            var nextPollTime: Date?

            for path in inflight.keys.sorted() {
                guard var active = inflight[path] else { continue }

                if active.nextPollAt > now {
                    nextPollTime = min(nextPollTime ?? active.nextPollAt, active.nextPollAt)
                    continue
                }

                do {
                    let refreshed = try ScanEngine.refreshedItem(at: active.sourceURL, relativePath: active.item.relativePath)
                    if refreshed.isLocalReady {
                        inflight.removeValue(forKey: path)
                        resolvedItems[path] = refreshed
                        downloadedCount += 1
                        await onEvent(.ready(refreshed, downloaded: true))
                        madeProgress = true
                        continue
                    }
                } catch {
                    if now.timeIntervalSince(active.startedAt) >= configuration.maxHydrationWait.timeInterval {
                        throw PipelineError.materializationFailed(active.item.relativePath)
                    }
                }

                if now.timeIntervalSince(active.startedAt) >= configuration.maxHydrationWait.timeInterval {
                    throw PipelineError.materializationFailed(active.item.relativePath)
                }

                let nextDelay = pollDelay(
                    forAttempt: active.pollAttempt,
                    schedule: configuration.backoffSchedule
                )
                active.pollAttempt += 1
                active.nextPollAt = now.addingTimeInterval(nextDelay.timeInterval)
                inflight[path] = active
                nextPollTime = min(nextPollTime ?? active.nextPollAt, active.nextPollAt)
            }

            guard !madeProgress else { continue }

            let sleepSeconds: TimeInterval
            if let nextPollTime {
                sleepSeconds = max(nextPollTime.timeIntervalSinceNow, 0.25)
            } else {
                sleepSeconds = 0.25
            }
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }

        let updatedItems = sortedItems.compactMap { resolvedItems[$0.relativePath] }
        return Report(items: updatedItems, downloadedCount: downloadedCount)
    }

    private func pollDelay(forAttempt attempt: Int, schedule: [Duration]) -> Duration {
        guard !schedule.isEmpty else {
            return .seconds(2)
        }
        if attempt < schedule.count {
            return schedule[attempt]
        }
        return schedule.last ?? .seconds(2)
    }
}

private struct PendingHydration {
    var item: ScannedItem
    var sourceURL: URL
}

private struct ActiveHydration {
    var item: ScannedItem
    var sourceURL: URL
    var startedAt: Date
    var nextPollAt: Date
    var pollAttempt: Int
}
