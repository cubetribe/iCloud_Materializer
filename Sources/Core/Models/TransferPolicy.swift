import Foundation

enum TransferMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case exactCopy
    case codingProject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exactCopy:
            return "Exact Copy"
        case .codingProject:
            return "Coding Project"
        }
    }

    var subtitle: String {
        switch self {
        case .exactCopy:
            return "Copy everything exactly as-is, except app-generated rescue artifacts."
        case .codingProject:
            return "Skip clearly rebuildable environments and caches."
        }
    }
}

struct TransferRuleDescriptor: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
}

enum ScanFilterDecision: Sendable, Equatable {
    case include
    case excludeItem(reason: String)
    case excludeDescendants(reason: String)
}

struct TransferPolicy: Hashable, Sendable {
    var mode: TransferMode
    var customExcludedDirectoryNames: [String]
    var customExcludedFileExtensions: [String]
    var ignoredCustomRules: [String]

    init(
        mode: TransferMode,
        customExcludedDirectoryNames: [String] = [],
        customExcludedFileExtensions: [String] = []
    ) {
        let customDirectories = Self.normalizeDirectoryNames(customExcludedDirectoryNames)
        let customExtensions = Self.normalizeFileExtensions(customExcludedFileExtensions)

        let blockedDirectories = customDirectories.filter(Self.blockedCustomDirectoryNames.contains)
        let blockedExtensions = customExtensions.filter(Self.blockedCustomFileExtensions.contains)

        self.mode = mode
        self.customExcludedDirectoryNames = customDirectories.filter { !Self.blockedCustomDirectoryNames.contains($0) }
        self.customExcludedFileExtensions = customExtensions.filter { !Self.blockedCustomFileExtensions.contains($0) }
        self.ignoredCustomRules = blockedDirectories.map { "Ignored custom directory exclusion: \($0)" } +
            blockedExtensions.map { "Ignored custom extension exclusion: .\($0)" }
    }

    static var exactCopy: TransferPolicy {
        TransferPolicy(mode: .exactCopy)
    }

    var isExactCopy: Bool {
        mode == .exactCopy
    }

    var hasActiveExclusions: Bool {
        !isExactCopy && (!activeExcludedDirectoryNames.isEmpty || !activeExcludedFileExtensions.isEmpty || !activeExcludedFileNames.isEmpty)
    }

    var ruleDescriptors: [TransferRuleDescriptor] {
        guard mode == .codingProject else {
            return [
                TransferRuleDescriptor(
                    id: "exact-copy",
                    title: "Exact copy",
                    detail: "Project content is copied as-is."
                ),
                TransferRuleDescriptor(
                    id: "internal-artifacts",
                    title: "Internal rescue artifacts",
                    detail: "Always skip app-generated rescue folders like .icloud-materializer and _Materializer_Archives."
                )
            ]
        }

        var rules = [
            TransferRuleDescriptor(
                id: "python-envs",
                title: "Python environments and caches",
                detail: ".venv, venv, env, __pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .tox, .nox, .eggs, .ipynb_checkpoints"
            ),
            TransferRuleDescriptor(
                id: "javascript-artifacts",
                title: "JavaScript dependencies and build caches",
                detail: "node_modules, .pnpm-store, .parcel-cache, .next, .nuxt, .svelte-kit, .turbo"
            ),
            TransferRuleDescriptor(
                id: "tooling-caches",
                title: "Tooling caches and generated build data",
                detail: ".gradle, .dart_tool, DerivedData"
            ),
            TransferRuleDescriptor(
                id: "generated-files",
                title: "Generated local files",
                detail: ".DS_Store, Thumbs.db, .pyc, .pyo"
            )
        ]

        if !customExcludedDirectoryNames.isEmpty {
            rules.append(
                TransferRuleDescriptor(
                    id: "custom-directories",
                    title: "Custom excluded directories",
                    detail: customExcludedDirectoryNames.joined(separator: ", ")
                )
            )
        }

        if !customExcludedFileExtensions.isEmpty {
            rules.append(
                TransferRuleDescriptor(
                    id: "custom-extensions",
                    title: "Custom excluded extensions",
                    detail: customExcludedFileExtensions.map { ".\($0)" }.joined(separator: ", ")
                )
            )
        }

        return rules
    }

    func scanDecision(relativePath: String, kind: ItemKind) -> ScanFilterDecision {
        if let internalArtifactDecision = Self.internalArtifactScanDecision(relativePath: relativePath, kind: kind) {
            return internalArtifactDecision
        }

        guard mode == .codingProject else {
            return .include
        }

        let lastComponent = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
        switch kind {
        case .directory:
            if activeExcludedDirectoryNames.contains(lastComponent) {
                return .excludeDescendants(reason: "Excluded generated directory \(lastComponent)")
            }
        case .file:
            if activeExcludedFileNames.contains(lastComponent) {
                return .excludeItem(reason: "Excluded generated file \(lastComponent)")
            }
            let pathExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
            if !pathExtension.isEmpty, activeExcludedFileExtensions.contains(pathExtension) {
                return .excludeItem(reason: "Excluded file extension .\(pathExtension)")
            }
        case .symlink:
            return .include
        }

        return .include
    }

    var runtimeSummary: String {
        switch mode {
        case .exactCopy:
            return "Transfer mode: Exact Copy (excluding internal rescue artifacts)"
        case .codingProject:
            return "Transfer mode: Coding Project with conservative exclusions"
        }
    }

    static func isInternalArtifactPath(_ relativePath: String) -> Bool {
        guard let firstComponent = firstPathComponent(of: relativePath) else {
            return false
        }
        return internalArtifactDirectoryNames.contains(firstComponent.lowercased())
    }

    static func isInternalArtifactDirectoryName(_ directoryName: String) -> Bool {
        internalArtifactDirectoryNames.contains(directoryName.lowercased())
    }

    var resumeFingerprint: String {
        let directories = customExcludedDirectoryNames.sorted().joined(separator: ",")
        let extensions = customExcludedFileExtensions.sorted().joined(separator: ",")
        return [
            mode.rawValue,
            directories,
            extensions
        ].joined(separator: "|")
    }

    private var activeExcludedDirectoryNames: Set<String> {
        Self.builtinExcludedDirectoryNames.union(customExcludedDirectoryNames)
    }

    private var activeExcludedFileExtensions: Set<String> {
        Self.builtinExcludedFileExtensions.union(customExcludedFileExtensions)
    }

    private var activeExcludedFileNames: Set<String> {
        Self.builtinExcludedFileNames
    }

    private static func normalizeDirectoryNames(_ values: [String]) -> Set<String> {
        Set(values
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) }
            .map { token in
                token
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        )
    }

    private static func normalizeFileExtensions(_ values: [String]) -> Set<String> {
        Set(values
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) }
            .map { token in
                token
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        )
    }

    private static func firstPathComponent(of relativePath: String) -> String? {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }

    private static func internalArtifactScanDecision(relativePath: String, kind: ItemKind) -> ScanFilterDecision? {
        guard let firstComponent = firstPathComponent(of: relativePath),
              internalArtifactDirectoryNames.contains(firstComponent.lowercased()) else {
            return nil
        }

        switch kind {
        case .directory:
            return .excludeDescendants(reason: "Excluded internal rescue directory \(firstComponent)")
        case .file, .symlink:
            return .excludeItem(reason: "Excluded internal rescue artifact \(firstComponent)")
        }
    }

    private static let internalArtifactDirectoryNames: Set<String> = [
        "_materializer_archives",
        ".icloud-materializer"
    ]

    private static let builtinExcludedDirectoryNames: Set<String> = [
        ".venv",
        "venv",
        "env",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".tox",
        ".nox",
        ".eggs",
        ".ipynb_checkpoints",
        "node_modules",
        ".pnpm-store",
        ".parcel-cache",
        ".next",
        ".nuxt",
        ".svelte-kit",
        ".turbo",
        ".gradle",
        ".dart_tool",
        "deriveddata"
    ]

    private static let builtinExcludedFileExtensions: Set<String> = [
        "pyc",
        "pyo"
    ]

    private static let builtinExcludedFileNames: Set<String> = [
        ".ds_store",
        "thumbs.db"
    ]

    private static let blockedCustomDirectoryNames: Set<String> = [
        ".github",
        "src",
        "sources",
        "source",
        "app",
        "apps",
        "lib",
        "libs",
        "tests",
        "test",
        "docs",
        "assets",
        "resources",
        "public"
    ]

    private static let blockedCustomFileExtensions: Set<String> = [
        "swift",
        "m",
        "mm",
        "h",
        "hpp",
        "c",
        "cc",
        "cpp",
        "py",
        "js",
        "jsx",
        "ts",
        "tsx",
        "json",
        "yaml",
        "yml",
        "toml",
        "md",
        "txt",
        "sql",
        "graphql",
        "plist",
        "xcconfig",
        "env",
        "rb",
        "php",
        "go",
        "rs",
        "java",
        "kt",
        "kts",
        "dart",
        "sh",
        "zsh",
        "fish",
        "ps1",
        "bat",
        "html",
        "css",
        "scss",
        "sass",
        "less",
        "vue",
        "svelte"
    ]
}
