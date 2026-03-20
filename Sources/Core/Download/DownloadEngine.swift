import Foundation

struct DownloadEngine: Sendable {
    enum Event: Sendable {
        case evaluating(ScannedItem)
        case deferred(ScannedItem, retryAfter: Duration)
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
        let fileManager = FileManager.default
        let sortedItems = configuration.priorityPolicy.sort(items: items)
        var resolvedItems: [String: ScannedItem] = [:]
        var downloadedCount = 0
        var hotQueue: [PendingHydration] = []
        var coolingQueue: [CoolingHydration] = []

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
            hotQueue.append(PendingHydration(item: item, sourceURL: sourceURL))
        }

        var inflight: [String: ActiveHydration] = [:]

        while !hotQueue.isEmpty || !coolingQueue.isEmpty || !inflight.isEmpty {
            try await pauseController.checkpoint()

            let now = Date()
            promoteCooledHydrations(into: &hotQueue, coolingQueue: &coolingQueue, now: now)

            while inflight.count < configuration.hydrationWindow, !hotQueue.isEmpty {
                let pending = hotQueue.removeFirst()
                await onEvent(.evaluating(pending.item))
                try? fileManager.startDownloadingUbiquitousItem(at: pending.sourceURL)
                inflight[pending.item.relativePath] = ActiveHydration(
                    item: pending.item,
                    sourceURL: pending.sourceURL,
                    firstRequestedAt: pending.firstRequestedAt ?? now,
                    slotStartedAt: now,
                    nextPollAt: now,
                    pollAttempt: 0,
                    restartCount: pending.restartCount
                )
            }

            if inflight.isEmpty {
                let nextCoolingTime = coolingQueue.map(\.retryAt).min()
                let sleepSeconds = max(nextCoolingTime?.timeIntervalSinceNow ?? 0.25, 0.25)
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                continue
            }

            var madeProgress = false
            var nextPollTime: Date?
            let queuedWorkExists = !hotQueue.isEmpty || !coolingQueue.isEmpty

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
                    if now.timeIntervalSince(active.firstRequestedAt) >= configuration.maxHydrationWait.timeInterval {
                        throw PipelineError.materializationFailed(active.item.relativePath)
                    }
                }

                if now.timeIntervalSince(active.firstRequestedAt) >= configuration.maxHydrationWait.timeInterval {
                    throw PipelineError.materializationFailed(active.item.relativePath)
                }

                if shouldCool(
                    active: active,
                    now: now,
                    hasQueuedWork: queuedWorkExists,
                    otherInflightCount: max(inflight.count - 1, 0),
                    hotSlotDuration: configuration.hydrationHotSlotDuration
                ) {
                    let retryAfter = coolingDelay(
                        forRestartCount: active.restartCount,
                        schedule: configuration.hydrationCooldownSchedule
                    )
                    inflight.removeValue(forKey: path)
                    coolingQueue.append(CoolingHydration(
                        item: active.item,
                        sourceURL: active.sourceURL,
                        firstRequestedAt: active.firstRequestedAt,
                        restartCount: active.restartCount + 1,
                        retryAt: now.addingTimeInterval(retryAfter.timeInterval)
                    ))
                    await onEvent(.deferred(active.item, retryAfter: retryAfter))
                    madeProgress = true
                    continue
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

            let nextCoolingTime = coolingQueue.map(\.retryAt).min()
            let wakeTimes = [nextPollTime, nextCoolingTime].compactMap { $0 }
            let sleepSeconds = max((wakeTimes.min()?.timeIntervalSinceNow) ?? 0.25, 0.25)
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }

        let updatedItems = sortedItems.compactMap { resolvedItems[$0.relativePath] }
        return Report(items: updatedItems, downloadedCount: downloadedCount)
    }

    func pollDelay(forAttempt attempt: Int, schedule: [Duration]) -> Duration {
        guard !schedule.isEmpty else {
            return .seconds(1)
        }
        let unclampedDelay: Duration
        if attempt < schedule.count {
            unclampedDelay = schedule[attempt]
        } else {
            unclampedDelay = schedule.last ?? .seconds(1)
        }

        let seconds = min(max(unclampedDelay.timeInterval, 0.25), 2.0)
        return .seconds(seconds)
    }

    func coolingDelay(forRestartCount restartCount: Int, schedule: [Duration]) -> Duration {
        guard !schedule.isEmpty else {
            return .seconds(60)
        }
        let index = min(max(restartCount, 0), schedule.count - 1)
        let delay = schedule[index]
        return .seconds(max(delay.timeInterval, 1.0))
    }

    func shouldCool(
        active: ActiveHydration,
        now: Date,
        hasQueuedWork: Bool,
        otherInflightCount: Int,
        hotSlotDuration: Duration
    ) -> Bool {
        guard now.timeIntervalSince(active.slotStartedAt) >= hotSlotDuration.timeInterval else {
            return false
        }
        return hasQueuedWork || otherInflightCount > 0
    }

    private func promoteCooledHydrations(
        into hotQueue: inout [PendingHydration],
        coolingQueue: inout [CoolingHydration],
        now: Date
    ) {
        guard !coolingQueue.isEmpty else { return }

        var retained: [CoolingHydration] = []
        for cooled in coolingQueue {
            if cooled.retryAt <= now {
                hotQueue.append(PendingHydration(
                    item: cooled.item,
                    sourceURL: cooled.sourceURL,
                    firstRequestedAt: cooled.firstRequestedAt,
                    restartCount: cooled.restartCount
                ))
            } else {
                retained.append(cooled)
            }
        }
        coolingQueue = retained
    }
}

private struct PendingHydration {
    var item: ScannedItem
    var sourceURL: URL
    var firstRequestedAt: Date? = nil
    var restartCount: Int = 0
}

struct ActiveHydration: Sendable {
    var item: ScannedItem
    var sourceURL: URL
    var firstRequestedAt: Date
    var slotStartedAt: Date
    var nextPollAt: Date
    var pollAttempt: Int
    var restartCount: Int
}

private struct CoolingHydration {
    var item: ScannedItem
    var sourceURL: URL
    var firstRequestedAt: Date
    var restartCount: Int
    var retryAt: Date
}
