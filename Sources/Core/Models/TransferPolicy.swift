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
            return "Copy everything exactly as-is."
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
                    detail: "No folders or file types are excluded."
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
            return "Transfer mode: Exact Copy"
        case .codingProject:
            return "Transfer mode: Coding Project with conservative exclusions"
        }
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
        ".git",
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
