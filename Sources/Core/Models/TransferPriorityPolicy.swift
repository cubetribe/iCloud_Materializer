import Foundation

enum TransferPriorityMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case naturalOrder
    case criticalFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naturalOrder:
            return "Natural Order"
        case .criticalFirst:
            return "Critical First"
        }
    }

    var subtitle: String {
        switch self {
        case .naturalOrder:
            return "Keep the default chunk order."
        case .criticalFirst:
            return "Start with environment files and base code before reports and logs."
        }
    }
}

enum TransferPriorityBand: Int, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case critical = 0
    case high = 1
    case standard = 2
    case deferred = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .critical:
            return "Critical"
        case .high:
            return "High"
        case .standard:
            return "Standard"
        case .deferred:
            return "Deferred"
        }
    }

    static func < (lhs: TransferPriorityBand, rhs: TransferPriorityBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TransferPriorityDescriptor: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
}

struct TransferPriorityPolicy: Hashable, Sendable {
    var mode: TransferPriorityMode

    static var naturalOrder: TransferPriorityPolicy {
        TransferPriorityPolicy(mode: .naturalOrder)
    }

    var ruleDescriptors: [TransferPriorityDescriptor] {
        guard mode == .criticalFirst else {
            return [
                TransferPriorityDescriptor(
                    id: "natural-order",
                    title: "Natural order",
                    detail: "No extra priority bands are applied."
                )
            ]
        }

        return [
            TransferPriorityDescriptor(
                id: "critical-files",
                title: "Critical environment files first",
                detail: ".env, .env.*, .envrc, .npmrc, .yarnrc, version markers, compose files, and other runtime entry configs."
            ),
            TransferPriorityDescriptor(
                id: "core-code",
                title: "Base code and manifests next",
                detail: "Core source folders, build manifests, dependency locks, scripts, and code/config file types move ahead of general content."
            ),
            TransferPriorityDescriptor(
                id: "standard-content",
                title: "Standard content",
                detail: "Everything not matched by a critical or deferred rule keeps a normal priority."
            ),
            TransferPriorityDescriptor(
                id: "deferred-artifacts",
                title: "Reports and logs later",
                detail: "Report, artifact, coverage, screenshot, and log-heavy paths are deferred, but still copied."
            )
        ]
    }

    var runtimeSummary: String {
        switch mode {
        case .naturalOrder:
            return "Priority mode: Natural Order"
        case .criticalFirst:
            return "Priority mode: Critical First"
        }
    }

    func inventorySummary(for items: [ScannedItem]) -> String? {
        guard mode == .criticalFirst else { return nil }
        let counts = items.reduce(into: [TransferPriorityBand: Int]()) { partial, item in
            partial[priority(for: item), default: 0] += 1
        }
        return TransferPriorityBand.allCases
            .map { band in
                "\(counts[band, default: 0]) \(band.title.lowercased())"
            }
            .joined(separator: ", ")
    }

    func priority(for item: ScannedItem) -> TransferPriorityBand {
        priority(relativePath: item.relativePath, kind: item.kind)
    }

    func priority(relativePath: String, kind: ItemKind) -> TransferPriorityBand {
        guard mode == .criticalFirst else {
            return .standard
        }

        let descriptor = PathDescriptor(relativePath: relativePath)
        if kind == .file, isCriticalEnvironmentFile(descriptor) {
            return .critical
        }
        if isDeferredArtifact(descriptor) {
            return .deferred
        }
        if isCoreProjectItem(descriptor, kind: kind) {
            return .high
        }
        return .standard
    }

    func sort(items: [ScannedItem]) -> [ScannedItem] {
        items.sorted(by: compare)
    }

    func sort(chunks: [ChunkManifest], itemMap: [String: ScannedItem]) -> [ChunkManifest] {
        guard mode == .criticalFirst else {
            return chunks
        }
        return chunks.sorted { lhs, rhs in
            let lhsBand = priorityBand(for: lhs, itemMap: itemMap)
            let rhsBand = priorityBand(for: rhs, itemMap: itemMap)
            if lhsBand != rhsBand {
                return lhsBand < rhsBand
            }
            if lhs.expectedBytes != rhs.expectedBytes {
                return lhs.expectedBytes < rhs.expectedBytes
            }
            if lhs.relativePaths.count != rhs.relativePaths.count {
                return lhs.relativePaths.count < rhs.relativePaths.count
            }
            return chunkSortKey(lhs) < chunkSortKey(rhs)
        }
    }

    private func compare(_ lhs: ScannedItem, _ rhs: ScannedItem) -> Bool {
        let lhsBand = priority(for: lhs)
        let rhsBand = priority(for: rhs)
        if lhsBand != rhsBand {
            return lhsBand < rhsBand
        }

        let lhsKindRank = kindRank(lhs.kind)
        let rhsKindRank = kindRank(rhs.kind)
        if lhsKindRank != rhsKindRank {
            return lhsKindRank < rhsKindRank
        }

        return lhs.relativePath < rhs.relativePath
    }

    private func priorityBand(for chunk: ChunkManifest, itemMap: [String: ScannedItem]) -> TransferPriorityBand {
        chunk.relativePaths
            .compactMap { itemMap[$0] }
            .map(priority(for:))
            .min() ?? .standard
    }

    private func chunkSortKey(_ chunk: ChunkManifest) -> String {
        chunk.anchorRelativePath ?? chunk.relativePaths.first ?? chunk.id.uuidString
    }

    private func kindRank(_ kind: ItemKind) -> Int {
        switch kind {
        case .directory:
            return 0
        case .symlink:
            return 1
        case .file:
            return 2
        }
    }

    private func isCriticalEnvironmentFile(_ descriptor: PathDescriptor) -> Bool {
        let name = descriptor.lastComponent
        if name == ".env" || name.hasPrefix(".env.") {
            return true
        }
        return Self.criticalEnvironmentFileNames.contains(name)
    }

    private func isCoreProjectItem(_ descriptor: PathDescriptor, kind: ItemKind) -> Bool {
        if let firstComponent = descriptor.firstComponent, Self.coreProjectDirectoryNames.contains(firstComponent) {
            return true
        }

        let name = descriptor.lastComponent
        if Self.coreProjectFileNames.contains(name) {
            return true
        }

        guard kind == .file else {
            return false
        }
        return !descriptor.fileExtension.isEmpty && Self.coreProjectFileExtensions.contains(descriptor.fileExtension)
    }

    private func isDeferredArtifact(_ descriptor: PathDescriptor) -> Bool {
        if descriptor.components.contains(where: Self.deferredDirectoryNames.contains) {
            return true
        }

        if Self.deferredFileNames.contains(descriptor.lastComponent) {
            return true
        }

        return !descriptor.fileExtension.isEmpty && Self.deferredFileExtensions.contains(descriptor.fileExtension)
    }

    private struct PathDescriptor {
        let components: [String]
        let firstComponent: String?
        let lastComponent: String
        let fileExtension: String

        init(relativePath: String) {
            let url = URL(fileURLWithPath: relativePath)
            self.components = relativePath
                .split(separator: "/")
                .map { String($0).lowercased() }
            self.firstComponent = components.first
            self.lastComponent = url.lastPathComponent.lowercased()
            self.fileExtension = url.pathExtension.lowercased()
        }
    }

    private static let criticalEnvironmentFileNames: Set<String> = [
        ".envrc",
        ".npmrc",
        ".yarnrc",
        ".pypirc",
        ".python-version",
        ".ruby-version",
        ".tool-versions",
        ".nvmrc",
        ".node-version",
        ".swift-version",
        ".xcode-version",
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml"
    ]

    private static let coreProjectDirectoryNames: Set<String> = [
        "src",
        "source",
        "sources",
        "app",
        "apps",
        "lib",
        "libs",
        "module",
        "modules",
        "package",
        "packages",
        "pkg",
        "server",
        "backend",
        "client",
        "frontend",
        "config",
        "configs",
        "script",
        "scripts",
        "bin",
        "cmd"
    ]

    private static let coreProjectFileNames: Set<String> = [
        "package.swift",
        "package.resolved",
        "package.json",
        "package-lock.json",
        "pnpm-lock.yaml",
        "yarn.lock",
        "bun.lockb",
        "pyproject.toml",
        "requirements.txt",
        "requirements-dev.txt",
        "requirements-prod.txt",
        "pipfile",
        "pipfile.lock",
        "poetry.lock",
        "gemfile",
        "gemfile.lock",
        "podfile",
        "podfile.lock",
        "cartfile",
        "cartfile.resolved",
        "dockerfile",
        "makefile",
        "justfile",
        "procfile"
    ]

    private static let coreProjectFileExtensions: Set<String> = [
        "swift",
        "m",
        "mm",
        "h",
        "c",
        "cc",
        "cpp",
        "cxx",
        "hpp",
        "hh",
        "js",
        "jsx",
        "ts",
        "tsx",
        "json",
        "yaml",
        "yml",
        "toml",
        "plist",
        "xcconfig",
        "sh",
        "zsh",
        "bash",
        "fish",
        "ps1",
        "py",
        "rb",
        "go",
        "rs",
        "java",
        "kt",
        "kts",
        "php",
        "sql",
        "graphql",
        "gql",
        "proto"
    ]

    private static let deferredDirectoryNames: Set<String> = [
        "reports",
        "report",
        "agent-reports",
        "agent_reports",
        "generated-reports",
        "generated_reports",
        "artifacts",
        "coverage",
        "logs",
        "screenshots",
        "diagnostics",
        "traces"
    ]

    private static let deferredFileNames: Set<String> = [
        "coverage-final.json"
    ]

    private static let deferredFileExtensions: Set<String> = [
        "log",
        "trace",
        "tmp",
        "bak"
    ]
}
