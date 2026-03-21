import Foundation

struct DownloadEngine: Sendable {
    enum Event: Sendable {
        case evaluating(ScannedItem)
        case requested(ScannedItem)
        case requestFailed(ScannedItem, message: String)
        case downloading(ScannedItem)
        case stalled(ScannedItem)
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
        hydrationSession: HydrationSession? = nil,
        onEvent: @escaping @Sendable (Event) async -> Void
    ) async throws -> Report {
        let sortedItems = configuration.priorityPolicy.sort(items: items)
        var resolvedItems: [String: ScannedItem] = [:]
        var downloadedCount = 0
        var hotQueue: [PendingHydration] = []
        var coolingQueue: [CoolingHydration] = []
        let hydrationSession = hydrationSession ?? HydrationSession(maxRequestedHydrations: configuration.maxRequestedHydrations)
        var adaptiveWindow = min(max(configuration.hydrationWindow, 1), 2)
        var readPressurePrimedPaths: Set<String> = []

        for item in sortedItems {
            try await pauseController.checkpoint()
            guard item.isUbiquitous, !item.isLocalReady else {
                await onEvent(.evaluating(item))
                var readyItem = item
                if readyItem.state == .pending {
                    readyItem.state = .localReady
                }
                readyItem.hydrationState = .ready
                readyItem.hydrationError = nil
                resolvedItems[readyItem.relativePath] = readyItem
                await onEvent(.ready(readyItem, downloaded: false))
                continue
            }

            let sourceURL = sourceRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            var pendingItem = item
            pendingItem.hydrationState = .notRequested
            hotQueue.append(PendingHydration(item: pendingItem, sourceURL: sourceURL))
        }
        var inflight: [String: ActiveHydration] = [:]
        do {
            while !hotQueue.isEmpty || !coolingQueue.isEmpty || !inflight.isEmpty {
                try await pauseController.checkpoint()

                let now = Date()
                promoteCooledHydrations(into: &hotQueue, coolingQueue: &coolingQueue, now: now)
                await prefetchQueuedHydrations(
                    hotQueue: hotQueue,
                    hydrationSession: hydrationSession,
                    scanDepth: configuration.localPrefetchScanDepth
                )
                try await applyReadPressurePrefetch(
                    hotQueue: hotQueue,
                    configuration: configuration,
                    pauseController: pauseController,
                    primedPaths: &readPressurePrimedPaths
                )

                while inflight.count < adaptiveWindow, !hotQueue.isEmpty {
                    var pending = hotQueue.removeFirst()
                    let target = HydrationTarget(
                        relativePath: pending.item.relativePath,
                        sourceURL: pending.sourceURL
                    )
                    await onEvent(.evaluating(pending.item))
                    switch await hydrationSession.activate(target: target) {
                    case .accepted, .alreadyRequested:
                        pending.item.hydrationState = .queued
                        pending.item.hydrationError = nil
                        await onEvent(.requested(pending.item))
                    case .failed(let message):
                        pending.item.hydrationState = .requestFailed
                        pending.item.hydrationError = message
                        await onEvent(.requestFailed(pending.item, message: message))
                        throw PipelineError.materializationFailed("\(pending.item.relativePath): \(message)")
                    }
                    inflight[pending.item.relativePath] = ActiveHydration(
                        item: pending.item,
                        sourceURL: pending.sourceURL,
                        firstRequestedAt: pending.firstRequestedAt ?? now,
                        slotStartedAt: now,
                        nextPollAt: now,
                        pollAttempt: 0,
                        restartCount: pending.restartCount,
                        didReportDownloading: false
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
                var deferredDuringLoop = false

                for path in inflight.keys.sorted() {
                    guard var active = inflight[path] else { continue }

                    if active.nextPollAt > now {
                        nextPollTime = min(nextPollTime ?? active.nextPollAt, active.nextPollAt)
                        continue
                    }

                    do {
                        var refreshed = try ScanEngine.refreshedItem(at: active.sourceURL, relativePath: active.item.relativePath)
                        if refreshed.isLocalReady {
                            inflight.removeValue(forKey: path)
                            await hydrationSession.finishActive(path: path, isReady: true)
                            refreshed.hydrationState = .ready
                            refreshed.hydrationError = nil
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
                        active.item.hydrationState = .stalled
                        await onEvent(.stalled(active.item))
                        throw PipelineError.materializationFailed(active.item.relativePath)
                    }

                    if !active.didReportDownloading {
                        active.didReportDownloading = true
                        active.item.hydrationState = .downloading
                        await onEvent(.downloading(active.item))
                    }

                    if active.restartCount >= configuration.retryCount {
                        active.item.hydrationState = .stalled
                        await onEvent(.stalled(active.item))
                        throw PipelineError.materializationFailed("\(active.item.relativePath): exceeded hydration retry budget")
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
                        await hydrationSession.finishActive(path: path, isReady: false)
                        var cooledItem = active.item
                        cooledItem.hydrationState = .stalled
                        coolingQueue.append(CoolingHydration(
                            item: cooledItem,
                            sourceURL: active.sourceURL,
                            firstRequestedAt: active.firstRequestedAt,
                            restartCount: active.restartCount + 1,
                            retryAt: now.addingTimeInterval(retryAfter.timeInterval)
                        ))
                        await onEvent(.stalled(cooledItem))
                        await onEvent(.deferred(cooledItem, retryAfter: retryAfter))
                        deferredDuringLoop = true
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

                if madeProgress, adaptiveWindow < configuration.hydrationWindow, inflight.count >= adaptiveWindow {
                    adaptiveWindow += 1
                } else if deferredDuringLoop, adaptiveWindow > 1 {
                    adaptiveWindow -= 1
                }

                guard !madeProgress else { continue }

                let nextCoolingTime = coolingQueue.map(\.retryAt).min()
                let wakeTimes = [nextPollTime, nextCoolingTime].compactMap { $0 }
                let sleepSeconds = max((wakeTimes.min()?.timeIntervalSinceNow) ?? 0.25, 0.25)
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        } catch {
            await hydrationSession.finishActive(paths: Array(inflight.keys))
            throw error
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

    private func prefetchQueuedHydrations(
        hotQueue: [PendingHydration],
        hydrationSession: HydrationSession,
        scanDepth: Int
    ) async {
        guard scanDepth > 0 else { return }
        let targets = hotQueue.prefix(scanDepth).map {
            HydrationTarget(relativePath: $0.item.relativePath, sourceURL: $0.sourceURL)
        }
        await hydrationSession.prefetch(targets: targets)
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

    private func applyReadPressurePrefetch(
        hotQueue: [PendingHydration],
        configuration: JobConfiguration,
        pauseController: PauseController,
        primedPaths: inout Set<String>
    ) async throws {
        guard configuration.readPressureConcurrency > 0 else { return }
        let readPressurePrefetchBudget = max(configuration.readPressureConcurrency * 4, 8)

        let candidates = hotQueue
            .prefix(min(configuration.localPrefetchScanDepth, readPressurePrefetchBudget))
            .filter { primedPaths.contains($0.item.relativePath) == false }
            .map { pending in
                HydrationPrimingCandidate(
                    url: pending.sourceURL,
                    relativePath: pending.item.relativePath
                )
            }

        guard !candidates.isEmpty else { return }

        _ = try await HydrationPrimer.prime(
            candidates: candidates,
            hydrationMode: .readPressureOnly,
            readPressureConcurrency: configuration.readPressureConcurrency,
            pauseController: pauseController
        )

        for candidate in candidates {
            primedPaths.insert(candidate.relativePath)
        }
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
    var didReportDownloading: Bool
}

struct HydrationTarget: Sendable {
    var relativePath: String
    var sourceURL: URL
}

actor HydrationSession {
    typealias RequestStarter = @Sendable (URL) throws -> Void

    enum ActivationResult: Sendable {
        case accepted
        case alreadyRequested
        case failed(String)
    }

    private struct PathState {
        var requestIssued = false
        var isReady = false
        var activeCount = 0
    }

    private let maxRequestedHydrations: Int
    private let requestStarter: RequestStarter
    private var states: [String: PathState] = [:]
    private var requestedPathCount = 0

    init(
        maxRequestedHydrations: Int,
        requestStarter: @escaping RequestStarter = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
    ) {
        self.maxRequestedHydrations = max(maxRequestedHydrations, 1)
        self.requestStarter = requestStarter
    }

    func prefetch(targets: [HydrationTarget]) {
        guard requestedPathCount < maxRequestedHydrations else { return }

        for target in targets {
            guard requestedPathCount < maxRequestedHydrations else { break }
            _ = issueRequestIfNeeded(for: target, allowBeyondLimit: false)
        }
    }

    func activate(target: HydrationTarget) -> ActivationResult {
        let result = issueRequestIfNeeded(for: target, allowBeyondLimit: true)
        if case .accepted = result {
            var state = states[target.relativePath] ?? PathState()
            state.activeCount += 1
            states[target.relativePath] = state
        } else if case .alreadyRequested = result {
            var state = states[target.relativePath] ?? PathState()
            state.activeCount += 1
            states[target.relativePath] = state
        }
        return result
    }

    func finishActive(path: String, isReady: Bool = false) {
        guard var state = states[path] else { return }
        if state.activeCount > 0 {
            state.activeCount -= 1
        }
        if isReady {
            markReady(&state)
        }
        states[path] = state
    }

    func finishActive(paths: [String]) {
        for path in paths {
            finishActive(path: path)
        }
    }

    func requestedHydrationCount() -> Int {
        requestedPathCount
    }

    func requestWasIssued(for path: String) -> Bool {
        states[path]?.requestIssued == true
    }

    func readyState(for path: String) -> Bool {
        states[path]?.isReady == true
    }

    private func issueRequestIfNeeded(for target: HydrationTarget, allowBeyondLimit: Bool) -> ActivationResult {
        var state = states[target.relativePath] ?? PathState()
        guard !state.isReady, !state.requestIssued else {
            states[target.relativePath] = state
            return .alreadyRequested
        }
        guard allowBeyondLimit || requestedPathCount < maxRequestedHydrations else {
            states[target.relativePath] = state
            return .alreadyRequested
        }

        do {
            try requestStarter(target.sourceURL)
            state.requestIssued = true
            requestedPathCount += 1
        } catch {
            states[target.relativePath] = state
            return .failed(error.localizedDescription)
        }

        states[target.relativePath] = state
        return .accepted
    }

    private func markReady(_ state: inout PathState) {
        guard !state.isReady else { return }
        state.isReady = true
        if state.requestIssued {
            state.requestIssued = false
            requestedPathCount = max(requestedPathCount - 1, 0)
        }
    }
}

private struct CoolingHydration {
    var item: ScannedItem
    var sourceURL: URL
    var firstRequestedAt: Date
    var restartCount: Int
    var retryAt: Date
}
