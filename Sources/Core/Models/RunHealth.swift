import Foundation

enum RunHealthLevel: String, Codable, Hashable, Sendable {
    case active
    case watch
    case stalled
}

struct RunHealthState: Hashable, Sendable {
    static let watchThreshold: TimeInterval = 90
    static let stalledThreshold: TimeInterval = 300

    var level: RunHealthLevel
    var message: String
    var secondsSinceProgress: TimeInterval

    static func evaluate(isRunning: Bool, lastProgressAt: Date?, now: Date) -> RunHealthState? {
        guard isRunning, let lastProgressAt else { return nil }

        let elapsed = max(0, now.timeIntervalSince(lastProgressAt))
        if elapsed >= stalledThreshold {
            return RunHealthState(
                level: .stalled,
                message: "No progress for \(formatDuration(elapsed)). The run may be stalled. Check the event stream before cancelling.",
                secondsSinceProgress: elapsed
            )
        }
        if elapsed >= watchThreshold {
            return RunHealthState(
                level: .watch,
                message: "No progress for \(formatDuration(elapsed)). This can still be normal during hydration, verification, or ZIP.",
                secondsSinceProgress: elapsed
            )
        }
        return RunHealthState(
            level: .active,
            message: "Last progress \(formatDuration(elapsed)) ago.",
            secondsSinceProgress: elapsed
        )
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter.string(from: seconds) ?? "0s"
    }
}
