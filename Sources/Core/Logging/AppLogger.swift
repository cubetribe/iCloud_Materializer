import Foundation

actor AppLogger {
    private var entries: [LogEntry] = []

    func append(level: LogLevel, message: String, path: String? = nil) -> LogEntry {
        let entry = LogEntry(
            id: UUID(),
            createdAt: Date(),
            level: level,
            message: message,
            path: path
        )
        entries.append(entry)
        return entry
    }

    func snapshot() -> [LogEntry] {
        entries
    }

    func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try entries.map { entry -> String in
            let data = try encoder.encode(entry)
            return String(decoding: data, as: UTF8.self)
        }
        let payload = lines.joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }
}
