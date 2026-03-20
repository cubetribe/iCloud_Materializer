import Darwin
import Foundation

actor FinderRecoveryEngine {
    typealias ProcessFactory = @Sendable (URL, URL) -> Process

    private let fileManager: FileManager
    private let processFactory: ProcessFactory
    private let pollIntervalNanoseconds: UInt64
    private let terminationGraceNanoseconds: UInt64

    init(
        fileManager: FileManager = .default,
        processFactory: @escaping ProcessFactory = FinderRecoveryEngine.makeRecoveryProcess,
        pollIntervalNanoseconds: UInt64 = 250_000_000,
        terminationGraceNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.fileManager = fileManager
        self.processFactory = processFactory
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.terminationGraceNanoseconds = terminationGraceNanoseconds
    }

    func recoverChunk(
        items: [ScannedItem],
        sourceRoot: URL,
        stageRoot: URL,
        pauseController: PauseController
    ) async throws {
        try await pauseController.checkpoint()

        if fileManager.fileExists(atPath: stageRoot.path) {
            try fileManager.removeItem(at: stageRoot)
        }
        try fileManager.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        for item in orderedItems(items) {
            try await pauseController.checkpoint()

            let sourceURL = sourceRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            let destinationURL = stageRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .directory)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            switch item.kind {
            case .directory:
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            case .symlink:
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                let target: String
                if let symlinkDestination = item.symlinkDestination {
                    target = symlinkDestination
                } else {
                    target = try fileManager.destinationOfSymbolicLink(atPath: sourceURL.path)
                }
                try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: target)
            case .file:
                try await runRecoveryCopy(from: sourceURL, to: destinationURL, pauseController: pauseController)
            }
        }
    }

    private func runRecoveryCopy(from sourceURL: URL, to destinationURL: URL, pauseController: PauseController) async throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let process = processFactory(sourceURL, destinationURL)
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()

        do {
            while process.isRunning {
                try await pauseController.checkpoint()
                if Task.isCancelled {
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        } catch {
            await terminate(process: process)
            throw error
        }

        let errorText = drainErrorOutput(from: stderr)
        guard process.terminationStatus == 0 else {
            throw PipelineError.finderRecoveryFailed(errorText.isEmpty ? "Recovery copy failed." : errorText)
        }
    }

    private func terminate(process: Process) async {
        guard process.isRunning else { return }

        process.interrupt()
        await waitForExit(of: process, forNanoseconds: pollIntervalNanoseconds)
        guard process.isRunning else { return }

        process.terminate()
        await waitForExit(of: process, forNanoseconds: terminationGraceNanoseconds)
        guard process.isRunning else { return }

        kill(process.processIdentifier, SIGKILL)
        await waitForExit(of: process, forNanoseconds: pollIntervalNanoseconds)
    }

    private func waitForExit(of process: Process, forNanoseconds duration: UInt64) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + duration
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: min(pollIntervalNanoseconds, 50_000_000))
        }
    }

    private func drainErrorOutput(from pipe: Pipe) -> String {
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func orderedItems(_ items: [ScannedItem]) -> [ScannedItem] {
        items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                if lhs.kind == .directory { return true }
                if rhs.kind == .directory { return false }
                if lhs.kind == .symlink { return true }
                if rhs.kind == .symlink { return false }
            }
            if lhs.pathComponents.count != rhs.pathComponents.count {
                return lhs.pathComponents.count < rhs.pathComponents.count
            }
            return lhs.relativePath < rhs.relativePath
        }
    }

    private static func makeRecoveryProcess(sourceURL: URL, destinationURL: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [sourceURL.path, destinationURL.path]
        return process
    }
}
