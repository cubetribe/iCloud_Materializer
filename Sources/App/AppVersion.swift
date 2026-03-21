import Foundation

struct AppVersion: Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    var rawValue: String {
        "\(major).\(minor).\(patch)"
    }

    var displayText: String {
        "Version \(rawValue)"
    }

    init?(parsing rawValue: String) {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }

        let numbers = components.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }

        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers[2]
    }

    static func load(from bundle: Bundle = .main) -> AppVersion? {
        if let url = bundle.url(forResource: "VERSION", withExtension: nil),
           let contents = try? String(contentsOf: url, encoding: .utf8),
           let version = AppVersion(parsing: contents) {
            return version
        }

        if let bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let version = AppVersion(parsing: bundledVersion) {
            return version
        }

        return nil
    }

    static func displayText(from bundle: Bundle = .main) -> String {
        load(from: bundle)?.displayText ?? "Version unavailable"
    }
}
