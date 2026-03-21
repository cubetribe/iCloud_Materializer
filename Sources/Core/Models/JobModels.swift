import CryptoKit
import Foundation

enum JobPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case preflight
    case discovering
    case scanning
    case planningChunks
    case hydrating
    case materializing
    case copying
    case verifyingChunks
    case promoting
    case finalVerifying
    case zipping
    case completed
    case completedWithWarnings
    case failed
    case cancelled
}

enum RunMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case singleProject
    case batchQueue

    var id: Self { self }

    var title: String {
        switch self {
        case .singleProject:
            return "Single Project"
        case .batchQueue:
            return "Batch Queue"
        }
    }

    var subtitle: String {
        switch self {
        case .singleProject:
            return "Copy one selected project into a local destination."
        case .batchQueue:
            return "Treat each direct subfolder in the selected source root as its own isolated project run."
        }
    }
}

enum BatchNamingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case suffix
    case prefix
    case template

    var id: Self { self }

    var title: String {
        switch self {
        case .suffix:
            return "Suffix"
        case .prefix:
            return "Prefix"
        case .template:
            return "Template"
        }
    }

    var subtitle: String {
        switch self {
        case .suffix:
            return "Append a value like `-Lokal` after each project name."
        case .prefix:
            return "Prepend a value like `Lokal-` before each project name."
        case .template:
            return "Use a full template with `{name}`, for example `{name}-Lokal` or `Lokal-{name}`."
        }
    }
}

enum BatchOrderingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case alphabetical

    var id: Self { self }

    var title: String {
        switch self {
        case .newestFirst:
            return "Newest First"
        case .oldestFirst:
            return "Oldest First"
        case .alphabetical:
            return "A-Z"
        }
    }

    var subtitle: String {
        switch self {
        case .newestFirst:
            return "Run the most recently changed top-level projects before older rescue candidates."
        case .oldestFirst:
            return "Drain the oldest top-level projects first."
        case .alphabetical:
            return "Keep a stable folder-name order."
        }
    }
}

enum RescueProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case conservative
    case aggressive

    var id: Self { self }

    var title: String {
        switch self {
        case .conservative:
            return "Conservative"
        case .aggressive:
            return "Aggressive"
        }
    }

    var subtitle: String {
        switch self {
        case .conservative:
            return "Favor predictable long rescue runs with smaller queues and no blind prewarm."
        case .aggressive:
            return "Use more CPU, I/O, and iCloud pressure to pull ready data back faster on a strong Mac."
        }
    }

    var workerRange: ClosedRange<Int> {
        switch self {
        case .conservative:
            return 1...4
        case .aggressive:
            return 2...16
        }
    }

    var hydrationRange: ClosedRange<Int> {
        switch self {
        case .conservative:
            return 2...8
        case .aggressive:
            return 4...24
        }
    }

    var defaultWorkerCount: Int {
        switch self {
        case .conservative:
            return 2
        case .aggressive:
            return 8
        }
    }

    var defaultHydrationWindow: Int {
        switch self {
        case .conservative:
            return 4
        case .aggressive:
            return 12
        }
    }

    var defaultRetryCount: Int {
        switch self {
        case .conservative:
            return 2
        case .aggressive:
            return 3
        }
    }

    var backoffSchedule: [Duration] {
        switch self {
        case .conservative:
            return [.seconds(0), .seconds(2), .seconds(5), .seconds(15)]
        case .aggressive:
            return [.seconds(0), .seconds(1), .seconds(2), .seconds(5)]
        }
    }

    var hydrationPrefetchWindow: Int {
        switch self {
        case .conservative:
            return 0
        case .aggressive:
            return 32
        }
    }

    var projectPrefetchWindow: Int {
        switch self {
        case .conservative:
            return 0
        case .aggressive:
            return 2
        }
    }

    var hydrationHotSlotDuration: Duration {
        switch self {
        case .conservative:
            return .seconds(6)
        case .aggressive:
            return .seconds(3)
        }
    }

    var runtimeSummary: String {
        switch self {
        case .conservative:
            return "Rescue profile: Conservative rescue with small queues, no batch prewarm, and lower system pressure"
        case .aggressive:
            return "Rescue profile: Aggressive rescue with larger queues, batch prewarm, and higher CPU/iCloud pressure"
        }
    }
}

enum BatchState: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case completed
    case completedWithWarnings
    case failed
    case cancelled
}

enum BatchProjectState: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case completed
    case completedWithWarnings
    case failed
    case conflicted
    case cancelled
}

enum ItemState: String, Codable, Sendable, CaseIterable {
    case pending
    case downloading
    case localReady
    case copied
    case failed
    case skippedSymlink
}

enum HydrationState: String, Codable, Sendable, CaseIterable {
    case notRequested
    case queued
    case downloading
    case stalled
    case requestFailed
    case ready
}

enum ChunkState: String, Codable, Sendable, CaseIterable {
    case pending
    case active
    case verified
    case promoted
    case failed
    case quarantined
}

enum FailureReason: String, Codable, Sendable, CaseIterable {
    case scan
    case materialize
    case copy
    case verification
    case promotion
    case zip
    case finderRecovery
    case cancelled
    case persistence
}

enum RecoveryMode: String, Codable, Sendable, CaseIterable {
    case direct
    case finder
}

enum ItemKind: String, Codable, Sendable, CaseIterable {
    case file
    case directory
    case symlink
}

enum ChunkKind: String, Codable, Sendable, CaseIterable {
    case directorySubtree
    case fileBatch
}

enum LogLevel: String, Codable, Sendable, CaseIterable {
    case info
    case warning
    case error
}

enum LiveActivityPhase: String, Codable, Sendable, CaseIterable {
    case preflight
    case discovering
    case scanning
    case planning
    case hydrating
    case materializing
    case copying
    case verifying
    case promoting
    case zipping
    case idle
}

enum PreflightCheckState: String, Codable, Sendable, CaseIterable {
    case passed
    case warning
    case actionRequired
}

struct PreflightCheck: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
    var state: PreflightCheckState
    var isManual: Bool = false
}

struct PreflightReport: Codable, Hashable, Sendable {
    var generatedAt: Date
    var checks: [PreflightCheck]

    static var empty: PreflightReport {
        PreflightReport(generatedAt: .distantPast, checks: [])
    }

    var blockingChecks: [PreflightCheck] {
        checks.filter { $0.state == .actionRequired }
    }

    var warningChecks: [PreflightCheck] {
        checks.filter { $0.state == .warning }
    }

    var canStart: Bool {
        blockingChecks.isEmpty
    }

    var blockingSummary: String? {
        guard !blockingChecks.isEmpty else { return nil }
        return blockingChecks.map(\.title).joined(separator: ", ")
    }
}

struct HydrationMetrics: Codable, Hashable, Sendable {
    var requestAttemptCount: Int = 0
    var requestFailureCount: Int = 0
    var queuedCount: Int = 0
    var downloadingCount: Int = 0
    var stalledCount: Int = 0
    var readyCount: Int = 0
    var timeToFirstDiscoveredSeconds: Double?
    var timeToFirstHydrationRequestSeconds: Double?
    var timeToFirstReadySeconds: Double?
    var timeToFirstCopiedSeconds: Double?
    var timeToFirstVerifiedChunkSeconds: Double?
}

struct ScannedItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var relativePath: String
    var kind: ItemKind
    var expectedSize: Int64
    var isHidden: Bool
    var isUbiquitous: Bool
    var isLocalReady: Bool
    var downloadStatusRaw: String?
    var symlinkDestination: String?
    var hydrationState: HydrationState = .ready
    var hydrationError: String? = nil
    var state: ItemState
    var lastError: String?
}

struct ChunkManifest: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var anchorRelativePath: String?
    var kind: ChunkKind
    var relativePaths: [String]
    var expectedBytes: Int64
    var state: ChunkState
    var recoveryMode: RecoveryMode
    var lastError: String?
}

struct FailureRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var relativePath: String
    var reason: FailureReason
    var message: String
    var recoveryMode: RecoveryMode
    var createdAt: Date
}

struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var level: LogLevel
    var message: String
    var path: String?
}

struct WorkerActivity: Identifiable, Hashable, Sendable {
    var id: UUID
    var label: String
    var phase: LiveActivityPhase
    var detail: String
    var path: String?
    var updatedAt: Date
}

struct JobSnapshot: Codable, Hashable, Sendable {
    var jobID: UUID
    var phase: JobPhase
    var phaseDetail: String?
    var sourcePath: String
    var destinationPath: String
    var currentPath: String?
    var totalDiscovered: Int
    var totalDownloaded: Int
    var totalCopied: Int
    var totalFailed: Int
    var plannedChunks: Int
    var processedChunks: Int
    var estimatedRemainingCount: Int
    var throughputItemsPerSecond: Double
    var throughputBytesPerSecond: Double
    var totalExpectedBytes: Int64
    var copiedBytes: Int64
    var activeWorkerCount: Int
    var estimatedRemainingSeconds: Double?
    var preflightReport: PreflightReport?
    var hydrationMetrics: HydrationMetrics
    var startedAt: Date?
    var finishedAt: Date?
    var lastError: String?

    static func idle(source: URL?, destination: URL?) -> JobSnapshot {
        JobSnapshot(
            jobID: UUID(),
            phase: .idle,
            phaseDetail: nil,
            sourcePath: source?.path ?? "",
            destinationPath: destination?.path ?? "",
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
            preflightReport: nil,
            hydrationMetrics: HydrationMetrics(),
            startedAt: nil,
            finishedAt: nil,
            lastError: nil
        )
    }
}

struct BatchProjectPlan: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourceURL: URL
    var destinationRootURL: URL
    var sourceFolderName: String
    var targetFolderName: String
    var state: BatchProjectState
    var detail: String?
    var archiveURL: URL?
    var deletionManifestURL: URL?
    var readyForDeletion: Bool
    var startedAt: Date?
    var finishedAt: Date?

    var targetURL: URL {
        destinationRootURL.appendingPathComponent(targetFolderName, isDirectory: true)
    }
}

struct BatchSnapshot: Codable, Hashable, Sendable {
    var batchID: UUID
    var state: BatchState
    var sourceRootPath: String
    var destinationRootPath: String
    var suffix: String
    var totalProjects: Int
    var completedProjects: Int
    var warningProjects: Int
    var failedProjects: Int
    var conflictedProjects: Int
    var readyForDeletionProjects: Int
    var currentProjectIndex: Int?
    var currentProjectName: String?
    var startedAt: Date?
    var finishedAt: Date?
    var lastError: String?

    static func idle(sourceRoot: URL?, destinationRoot: URL?, suffix: String) -> BatchSnapshot {
        BatchSnapshot(
            batchID: UUID(),
            state: .idle,
            sourceRootPath: sourceRoot?.path ?? "",
            destinationRootPath: destinationRoot?.path ?? "",
            suffix: suffix,
            totalProjects: 0,
            completedProjects: 0,
            warningProjects: 0,
            failedProjects: 0,
            conflictedProjects: 0,
            readyForDeletionProjects: 0,
            currentProjectIndex: nil,
            currentProjectName: nil,
            startedAt: nil,
            finishedAt: nil,
            lastError: nil
        )
    }
}

struct JobConfiguration: Sendable {
    var jobID: UUID
    var sourceURL: URL
    var destinationURL: URL
    var targetFolderName: String? = nil
    var finalArchiveURL: URL? = nil
    var preflightReport: PreflightReport? = nil
    var rescueProfile: RescueProfile = .conservative
    var transferPolicy: TransferPolicy
    var priorityPolicy: TransferPriorityPolicy
    var workerCount: Int
    var hydrationWindow: Int
    var retryCount: Int
    var backoffSchedule: [Duration]
    var maxHydrationWait: Duration
    var shouldCreateArchive: Bool = false
    var hydrationPrefetchWindow: Int = 24
    var hydrationHotSlotDuration: Duration = .seconds(4)
    var hydrationCooldownSchedule: [Duration] = [.seconds(10), .seconds(45), .seconds(120)]
    var allowTargetQuarantine: Bool
    var enableFinderFallback: Bool

    var resumeKey: String {
        Self.makeResumeKey(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            targetFolderName: targetFolderName,
            transferPolicy: transferPolicy
        )
    }

    var visibleTargetURL: URL {
        destinationURL.appendingPathComponent(targetFolderName ?? sourceURL.lastPathComponent, isDirectory: true)
    }

    var workingRootURL: URL {
        destinationURL
            .appendingPathComponent(".icloud-materializer", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    var databaseURL: URL {
        workingRootURL.appendingPathComponent("state.sqlite", isDirectory: false)
    }

    var maxActiveHydrations: Int {
        max(workerCount, 1) * max(hydrationWindow, 1)
    }

    var effectiveHydrationPrefetchBuffer: Int {
        let configuredBuffer = max(hydrationPrefetchWindow, 0)
        let conservativeCap = max(8, maxActiveHydrations / 2)
        return min(configuredBuffer, conservativeCap)
    }

    var maxRequestedHydrations: Int {
        maxActiveHydrations + effectiveHydrationPrefetchBuffer
    }

    var localPrefetchScanDepth: Int {
        max(hydrationWindow, 1) + effectiveHydrationPrefetchBuffer
    }

    var topLevelWarmupConcurrency: Int {
        guard rescueProfile == .aggressive else { return 0 }
        return min(max(workerCount, 2), 8)
    }

    static func resumeJobID(
        sourceURL: URL,
        destinationURL: URL,
        targetFolderName: String?,
        transferPolicy: TransferPolicy
    ) -> UUID {
        deterministicUUID(
            seed: makeResumeKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                targetFolderName: targetFolderName,
                transferPolicy: transferPolicy
            )
        )
    }

    private static func makeResumeKey(
        sourceURL: URL,
        destinationURL: URL,
        targetFolderName: String?,
        transferPolicy: TransferPolicy
    ) -> String {
        let sourcePath = sourceURL.standardizedFileURL.path.lowercased()
        let destinationPath = destinationURL.standardizedFileURL.path.lowercased()
        let target = (targetFolderName ?? sourceURL.lastPathComponent).lowercased()
        return [
            sourcePath,
            destinationPath,
            target,
            transferPolicy.resumeFingerprint
        ].joined(separator: "|")
    }

    private static func deterministicUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct BatchConfiguration: Sendable {
    var batchID: UUID
    var sourceRootURL: URL
    var destinationRootURL: URL
    var namingMode: BatchNamingMode = .suffix
    var orderingMode: BatchOrderingMode = .newestFirst
    var suffix: String
    var rescueProfile: RescueProfile = .conservative
    var transferPolicy: TransferPolicy
    var priorityPolicy: TransferPriorityPolicy
    var workerCount: Int
    var hydrationWindow: Int
    var retryCount: Int
    var backoffSchedule: [Duration]
    var maxHydrationWait: Duration
    var shouldCreateArchive: Bool = false
    var hydrationPrefetchWindow: Int = 0
    var hydrationHotSlotDuration: Duration = .seconds(6)
    var enableFinderFallback: Bool
    var projectPrefetchWindow: Int = 4

    var archiveRootURL: URL {
        sourceRootURL.appendingPathComponent("_Materializer_Archives", isDirectory: true)
    }

    var resumeRootURL: URL {
        destinationRootURL
            .appendingPathComponent(".icloud-materializer", isDirectory: true)
            .appendingPathComponent("batch-resume", isDirectory: true)
            .appendingPathComponent(resumeKey, isDirectory: true)
    }

    var resumeStateURL: URL {
        resumeRootURL.appendingPathComponent("batch-state.json", isDirectory: false)
    }

    var deletionManifestRootURL: URL {
        destinationRootURL
            .appendingPathComponent(".icloud-materializer", isDirectory: true)
            .appendingPathComponent("batches", isDirectory: true)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent("deletion-manifests", isDirectory: true)
    }

    var resumeKey: String {
        let source = sourceRootURL.standardizedFileURL.path.lowercased()
        let destination = destinationRootURL.standardizedFileURL.path.lowercased()
        let namingKey: String
        switch namingMode {
        case .suffix:
            namingKey = effectiveSuffix.lowercased()
        case .prefix:
            namingKey = "prefix:\(effectivePrefix.lowercased())"
        case .template:
            namingKey = "template:\(effectiveTemplate.lowercased())"
        }
        let payload = "\(source)|\(destination)|\(namingKey)"
        return payload
            .unicodeScalars
            .map { scalar -> String in
                if CharacterSet.alphanumerics.contains(scalar) {
                    return String(scalar)
                }
                return "_"
            }
            .joined()
    }

    var effectiveSuffix: String {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("_") || trimmed.hasPrefix(" ") {
            return trimmed
        }
        return "-\(trimmed)"
    }

    var effectivePrefix: String {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasSuffix("-") || trimmed.hasSuffix("_") || trimmed.hasSuffix(" ") {
            return trimmed
        }
        return "\(trimmed)-"
    }

    var effectiveTemplate: String {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{name}" }
        if trimmed.contains("{name}") {
            return trimmed
        }
        return "{name}-\(trimmed)"
    }

    var namingSummary: String {
        switch namingMode {
        case .suffix:
            return effectiveSuffix.isEmpty ? "Suffix: none" : "Suffix: \(effectiveSuffix)"
        case .prefix:
            return effectivePrefix.isEmpty ? "Prefix: none" : "Prefix: \(effectivePrefix)"
        case .template:
            return "Template: \(effectiveTemplate)"
        }
    }

    func targetFolderName(for projectName: String) -> String {
        switch namingMode {
        case .suffix:
            return projectName + effectiveSuffix
        case .prefix:
            return effectivePrefix + projectName
        case .template:
            return effectiveTemplate.replacingOccurrences(of: "{name}", with: projectName)
        }
    }

    func jobConfiguration(for plan: BatchProjectPlan) -> JobConfiguration {
        JobConfiguration(
            jobID: UUID(),
            sourceURL: plan.sourceURL,
            destinationURL: destinationRootURL,
            targetFolderName: plan.targetFolderName,
            finalArchiveURL: shouldCreateArchive ? archiveRootURL.appendingPathComponent("\(plan.sourceFolderName).zip", isDirectory: false) : nil,
            rescueProfile: rescueProfile,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: workerCount,
            hydrationWindow: hydrationWindow,
            retryCount: retryCount,
            backoffSchedule: backoffSchedule,
            maxHydrationWait: maxHydrationWait,
            shouldCreateArchive: shouldCreateArchive,
            hydrationPrefetchWindow: hydrationPrefetchWindow,
            hydrationHotSlotDuration: hydrationHotSlotDuration,
            allowTargetQuarantine: false,
            enableFinderFallback: enableFinderFallback
        )
    }
}

struct DeletionManifest: Codable, Hashable, Sendable {
    var batchID: UUID
    var projectID: UUID
    var projectName: String
    var sourceURL: URL
    var localCopyURL: URL
    var archiveURL: URL
    var createdAt: Date
    var sourceDeleteSuggested: Bool
    var notes: String
}

struct PersistedBatchRun: Codable, Hashable, Sendable {
    var snapshot: BatchSnapshot
    var projects: [BatchProjectPlan]
    var updatedAt: Date
}

struct WorkingDirectories: Sendable {
    var root: URL
    var stagingRoot: URL
    var assembledRoot: URL
    var archiveRoot: URL
    var quarantineRoot: URL
}

enum JobUpdate: Sendable {
    case snapshot(JobSnapshot)
    case log(LogEntry)
    case failures([FailureRecord])
    case activities([WorkerActivity])
    case batchSnapshot(BatchSnapshot)
    case batchProjects([BatchProjectPlan])
}

struct PromotionConflictState: Identifiable, Sendable {
    let id = UUID()
    let existingTarget: URL
}

struct VerificationResult: Sendable {
    var verifiedCount: Int
    var verifiedBytes: Int64
}

struct ChunkOutcome: Sendable {
    var chunkID: UUID
    var copiedCount: Int
    var downloadedCount: Int
    var recoveryMode: RecoveryMode
    var failures: [FailureRecord]
}

extension ScannedItem {
    var pathComponents: [String] {
        relativePath.split(separator: "/").map(String.init)
    }

    var parentRelativePath: String? {
        let components = pathComponents
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }
}

extension Array where Element == ScannedItem {
    var expectedBytes: Int64 {
        reduce(into: 0) { partial, item in
            if item.kind == .file {
                partial += item.expectedSize
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
