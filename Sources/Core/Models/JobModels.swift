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

struct JobSnapshot: Codable, Hashable, Sendable {
    var jobID: UUID
    var phase: JobPhase
    var sourcePath: String
    var destinationPath: String
    var currentPath: String?
    var totalDiscovered: Int
    var totalDownloaded: Int
    var totalCopied: Int
    var totalFailed: Int
    var estimatedRemainingCount: Int
    var throughputItemsPerSecond: Double
    var startedAt: Date?
    var finishedAt: Date?
    var lastError: String?

    static func idle(source: URL?, destination: URL?) -> JobSnapshot {
        JobSnapshot(
            jobID: UUID(),
            phase: .idle,
            sourcePath: source?.path ?? "",
            destinationPath: destination?.path ?? "",
            currentPath: nil,
            totalDiscovered: 0,
            totalDownloaded: 0,
            totalCopied: 0,
            totalFailed: 0,
            estimatedRemainingCount: 0,
            throughputItemsPerSecond: 0,
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
    var workerCount: Int
    var retryCount: Int
    var backoffSchedule: [Duration]
    var allowTargetQuarantine: Bool
    var enableFinderFallback: Bool

    var visibleTargetURL: URL {
        destinationURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
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
