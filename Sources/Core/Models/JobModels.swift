import Foundation

enum JobPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case scanning
    case planningChunks
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
    case scanning
    case planning
    case materializing
    case copying
    case verifying
    case promoting
    case zipping
    case idle
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
    var transferPolicy: TransferPolicy
    var priorityPolicy: TransferPriorityPolicy
    var workerCount: Int
    var hydrationWindow: Int
    var retryCount: Int
    var backoffSchedule: [Duration]
    var maxHydrationWait: Duration
    var allowTargetQuarantine: Bool
    var enableFinderFallback: Bool

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
}

struct BatchConfiguration: Sendable {
    var batchID: UUID
    var sourceRootURL: URL
    var destinationRootURL: URL
    var suffix: String
    var transferPolicy: TransferPolicy
    var priorityPolicy: TransferPriorityPolicy
    var workerCount: Int
    var hydrationWindow: Int
    var retryCount: Int
    var backoffSchedule: [Duration]
    var maxHydrationWait: Duration
    var enableFinderFallback: Bool

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
        let suffixPart = effectiveSuffix.lowercased()
        let payload = "\(source)|\(destination)|\(suffixPart)"
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

    func targetFolderName(for projectName: String) -> String {
        projectName + effectiveSuffix
    }

    func jobConfiguration(for plan: BatchProjectPlan) -> JobConfiguration {
        JobConfiguration(
            jobID: UUID(),
            sourceURL: plan.sourceURL,
            destinationURL: destinationRootURL,
            targetFolderName: plan.targetFolderName,
            finalArchiveURL: archiveRootURL.appendingPathComponent("\(plan.sourceFolderName).zip", isDirectory: false),
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: workerCount,
            hydrationWindow: hydrationWindow,
            retryCount: retryCount,
            backoffSchedule: backoffSchedule,
            maxHydrationWait: maxHydrationWait,
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
