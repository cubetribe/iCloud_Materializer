import Foundation

struct PreflightEngine {
    static let syncThisMacCheckID = "sync-this-mac"
    static let finderStatusCheckID = "finder-status"
    static let permissionsCheckID = "permissions"
    static let thirdPartySyncCheckID = "third-party-sync"

    private let fileManager = FileManager.default
    private let lowSpaceThresholdBytes: Int64 = 20 * 1024 * 1024 * 1024
    private let warningSpaceThresholdBytes: Int64 = 100 * 1024 * 1024 * 1024

    func evaluate(
        sourceURL: URL?,
        destinationURL: URL?,
        transferPolicy: TransferPolicy,
        confirmations: Set<String>
    ) -> PreflightReport {
        var checks: [PreflightCheck] = []

        guard let sourceURL, let destinationURL else {
            checks.append(
                PreflightCheck(
                    id: "folders-selected",
                    title: "Select source and destination",
                    detail: "Choose an iCloud source and a local destination before running preflight.",
                    state: .actionRequired
                )
            )
            return PreflightReport(generatedAt: Date(), checks: checks)
        }

        checks.append(sourceReachabilityCheck(sourceURL))
        checks.append(destinationWritabilityCheck(destinationURL))
        checks.append(destinationLocationCheck(destinationURL))
        checks.append(freeSpaceCheck(destinationURL))
        checks.append(availabilityCheck(sourceURL))
        if let scanRiskCheck = scanRiskCheck(sourceURL: sourceURL, transferPolicy: transferPolicy) {
            checks.append(scanRiskCheck)
        }

        checks.append(
            manualCheck(
                id: Self.syncThisMacCheckID,
                title: "Confirm 'Sync this Mac' is enabled",
                detail: "Open System Settings > Apple Account > iCloud > Drive and verify that this Mac is syncing iCloud Drive.",
                confirmations: confirmations
            )
        )
        checks.append(
            manualCheck(
                id: Self.finderStatusCheckID,
                title: "Review Finder iCloud status and apply 'Keep Downloaded'",
                detail: "In Finder, show iCloud Status for the source root and apply 'Keep Downloaded' to the root or top-level project folders before starting.",
                confirmations: confirmations
            )
        )
        checks.append(
            manualCheck(
                id: Self.permissionsCheckID,
                title: "Review Privacy & Security permissions",
                detail: "Confirm Files and Folders, Full Disk Access, and Finder Automation access are granted if macOS requested them.",
                confirmations: confirmations
            )
        )
        checks.append(
            manualCheck(
                id: Self.thirdPartySyncCheckID,
                title: "Disable competing sync tools",
                detail: "Pause Dropbox, OneDrive, Google Drive, or any other tool that may also monitor Desktop/Documents while the rescue runs.",
                confirmations: confirmations
            )
        )

        return PreflightReport(generatedAt: Date(), checks: checks)
    }

    private func sourceReachabilityCheck(_ sourceURL: URL) -> PreflightCheck {
        do {
            _ = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
            return PreflightCheck(
                id: "source-reachable",
                title: "Source root is readable",
                detail: sourceURL.path,
                state: .passed
            )
        } catch {
            return PreflightCheck(
                id: "source-reachable",
                title: "Source root is readable",
                detail: "macOS could not enumerate the source root: \(error.localizedDescription)",
                state: .actionRequired
            )
        }
    }

    private func destinationWritabilityCheck(_ destinationURL: URL) -> PreflightCheck {
        let probeURL = destinationURL.appendingPathComponent(".icloud-materializer-preflight-\(UUID().uuidString)", isDirectory: false)
        do {
            try Data("probe".utf8).write(to: probeURL, options: .atomic)
            try? fileManager.removeItem(at: probeURL)
            return PreflightCheck(
                id: "destination-writable",
                title: "Destination is writable",
                detail: destinationURL.path,
                state: .passed
            )
        } catch {
            return PreflightCheck(
                id: "destination-writable",
                title: "Destination is writable",
                detail: "The destination root is not currently writable: \(error.localizedDescription)",
                state: .actionRequired
            )
        }
    }

    private func destinationLocationCheck(_ destinationURL: URL) -> PreflightCheck {
        if isLikelyICloudPath(destinationURL) {
            return PreflightCheck(
                id: "destination-local",
                title: "Destination stays outside iCloud Drive",
                detail: "Choose a destination outside iCloud Drive. Rescue targets inside iCloud reintroduce File Provider latency.",
                state: .actionRequired
            )
        }

        return PreflightCheck(
            id: "destination-local",
            title: "Destination stays outside iCloud Drive",
            detail: destinationURL.path,
            state: .passed
        )
    }

    private func freeSpaceCheck(_ destinationURL: URL) -> PreflightCheck {
        do {
            let values = try destinationURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let bytes = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let detail = "Free space: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            if bytes <= lowSpaceThresholdBytes {
                return PreflightCheck(
                    id: "free-space",
                    title: "Destination has enough free space",
                    detail: "\(detail). Keep significantly more free space available before starting a large rescue.",
                    state: .actionRequired
                )
            }
            if bytes <= warningSpaceThresholdBytes {
                return PreflightCheck(
                    id: "free-space",
                    title: "Destination has enough free space",
                    detail: "\(detail). This may still be tight for large iCloud rescues.",
                    state: .warning
                )
            }
            return PreflightCheck(
                id: "free-space",
                title: "Destination has enough free space",
                detail: detail,
                state: .passed
            )
        } catch {
            return PreflightCheck(
                id: "free-space",
                title: "Destination has enough free space",
                detail: "macOS did not report free-space information: \(error.localizedDescription)",
                state: .warning
            )
        }
    }

    private func availabilityCheck(_ sourceURL: URL) -> PreflightCheck {
        let resourceKeys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        do {
            let children = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants]
            )
            let unavailableCount = children.reduce(into: 0) { count, child in
                guard let values = try? child.resourceValues(forKeys: Set(resourceKeys)) else { return }
                guard values.isUbiquitousItem == true else { return }
                let status = values.ubiquitousItemDownloadingStatus
                if status != .current && status != .downloaded {
                    count += 1
                }
            }
            guard unavailableCount > 0 else {
                return PreflightCheck(
                    id: "availability",
                    title: "Top-level source items are locally ready",
                    detail: "No cold top-level iCloud items were detected.",
                    state: .passed
                )
            }
            return PreflightCheck(
                id: "availability",
                title: "Top-level source items are locally ready",
                detail: "\(unavailableCount) top-level iCloud items are still cloud-only. Use Finder > Keep Downloaded before starting the rescue.",
                state: .actionRequired
            )
        } catch {
            return PreflightCheck(
                id: "availability",
                title: "Top-level source items are locally ready",
                detail: "Unable to inspect top-level iCloud availability: \(error.localizedDescription)",
                state: .warning
            )
        }
    }

    private func scanRiskCheck(sourceURL: URL, transferPolicy: TransferPolicy) -> PreflightCheck? {
        let gitObjectsURL = sourceURL.appendingPathComponent(".git/objects", isDirectory: true)
        guard fileManager.fileExists(atPath: gitObjectsURL.path) else { return nil }

        switch transferPolicy.mode {
        case .exactCopy:
            return PreflightCheck(
                id: "scan-risk-git",
                title: "Git object storage will slow discovery",
                detail: "This source contains `.git/objects`. Exact Copy will inventory the entire Git object store, which can dominate scan time before copying starts.",
                state: .warning
            )
        case .codingProject:
            if transferPolicy.customExcludedDirectoryNames.contains(".git") {
                return PreflightCheck(
                    id: "scan-risk-git",
                    title: "Git history is excluded for this run",
                    detail: "Custom directory exclusions already skip `.git`, so discovery should avoid the Git object store.",
                    state: .passed
                )
            }
            return PreflightCheck(
                id: "scan-risk-git",
                title: "Git history may dominate scan time",
                detail: "This source contains `.git/objects`, and Coding Project mode still includes Git history unless you explicitly exclude `.git` in the custom directory list.",
                state: .warning
            )
        }
    }

    private func manualCheck(
        id: String,
        title: String,
        detail: String,
        confirmations: Set<String>
    ) -> PreflightCheck {
        PreflightCheck(
            id: id,
            title: title,
            detail: detail,
            state: confirmations.contains(id) ? .passed : .actionRequired,
            isManual: true
        )
    }

    private func isLikelyICloudPath(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        if standardizedPath.contains("/Mobile Documents/") {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }
}
