import Foundation

final class AppSessionLog: @unchecked Sendable {
    struct Record: Codable, Sendable {
        var createdAt: Date
        var category: String
        var level: LogLevel
        var message: String
        var path: String?
    }

    static let shared = AppSessionLog()

    let directoryURL: URL
    let sessionLogURL: URL
    let latestLogURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        sessionDate: Date = Date()
    ) {
        self.fileManager = fileManager

        let logsRoot = baseDirectoryURL ??
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("iCloudMaterializer", isDirectory: true)

        self.directoryURL = logsRoot
        self.latestLogURL = logsRoot.appendingPathComponent("latest.log.jsonl", isDirectory: false)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let sessionName = "session-\(formatter.string(from: sessionDate)).log.jsonl"
        self.sessionLogURL = logsRoot.appendingPathComponent(sessionName, isDirectory: false)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        prepareLogFiles()
        append(
            level: .info,
            category: "lifecycle",
            message: "Session started. \(AppVersion.displayText())",
            path: nil
        )
    }

    func append(entry: LogEntry, category: String = "pipeline") {
        append(
            level: entry.level,
            category: category,
            message: entry.message,
            path: entry.path,
            createdAt: entry.createdAt
        )
    }

    func append(
        level: LogLevel,
        category: String,
        message: String,
        path: String? = nil,
        createdAt: Date = Date()
    ) {
        let record = Record(
            createdAt: createdAt,
            category: category,
            level: level,
            message: message,
            path: path
        )

        guard let data = try? encoder.encode(record) else { return }
        let line = data + Data([0x0A])

        lock.lock()
        defer { lock.unlock() }
        append(line, to: sessionLogURL)
        append(line, to: latestLogURL)
    }

    private func prepareLogFiles() {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileManager.createFile(atPath: sessionLogURL.path, contents: nil)
        try? Data().write(to: latestLogURL, options: .atomic)
    }

    private func append(_ data: Data, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            fileManager.createFile(atPath: url.path, contents: data)
            return
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
}
