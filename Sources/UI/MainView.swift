import SwiftUI

struct MainView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                mainContent
            }
            .padding(20)
        }
        .frame(minWidth: 1280, minHeight: 920)
        .onChange(of: viewModel.runMode, initial: true) { _, _ in
            viewModel.rebuildBatchPreview()
        }
        .alert("Destination Exists", isPresented: Binding(
            get: { viewModel.pendingConflict != nil },
            set: { if !$0 { viewModel.pendingConflict = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingConflict = nil
            }
            Button("Quarantine and Continue") {
                viewModel.startAfterQuarantineApproval()
            }
        } message: {
            Text("The target folder already exists at \(viewModel.pendingConflict?.existingTarget.path ?? ""). It will be moved into the job quarantine area before the run continues.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("iCloud Materializer")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(viewModel.snapshot.phaseDetail ?? "Choose a source and a destination, then start the job.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let currentPath = viewModel.snapshot.currentPath, !currentPath.isEmpty {
                    Text(currentPath)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                phaseBadge(for: viewModel.snapshot.phase)
                Text(etaText)
                    .font(.system(.headline, design: .rounded))
            }
        }
    }

    private var foldersSection: some View {
        GroupBox("Folders") {
            VStack(alignment: .leading, spacing: 10) {
                folderRow(title: viewModel.runMode == .singleProject ? "Source" : "Batch Source Root", path: viewModel.sourceURL?.path) {
                    viewModel.chooseSourceFolder()
                }
                folderRow(title: viewModel.runMode == .singleProject ? "Destination" : "Batch Destination Root", path: viewModel.destinationURL?.path) {
                    viewModel.chooseDestinationFolder()
                }
            }
        }
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                foldersSection
                if viewModel.runMode == .batchQueue {
                    batchQueueSection
                }
                telemetrySection
                liveProgressSection
                bottomRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rightRail
        }
    }

    private var telemetrySection: some View {
        GroupBox("Telemetry") {
            VStack(alignment: .leading, spacing: 14) {
                metricsGrid
                Divider()
                chunkGrid
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Run Mode") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: $viewModel.runMode) {
                        ForEach(RunMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isRunning)

                    Text(viewModel.runMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.runMode == .batchQueue {
                        TextField("Suffix, e.g. Lokal or Copy", text: $viewModel.batchSuffix)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isRunning)
                            .onChange(of: viewModel.batchSuffix, initial: false) { _, _ in
                                viewModel.rebuildBatchPreview()
                            }
                        Text(batchSuffixPreviewText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 360, alignment: .leading)

            GroupBox("Transfer Scope") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: $viewModel.transferMode) {
                        ForEach(TransferMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isRunning)

                    Text(viewModel.transferPolicy.mode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Source files are never deleted. This only narrows what gets inventoried and copied for this run.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.transferMode == .codingProject {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Custom excluded directory names, e.g. vendor_cache,temp_env", text: $viewModel.customExcludedDirectoryNamesText)
                                .textFieldStyle(.roundedBorder)
                                .disabled(viewModel.isRunning)
                            TextField("Custom excluded file extensions, e.g. sqlite,db-shm", text: $viewModel.customExcludedFileExtensionsText)
                                .textFieldStyle(.roundedBorder)
                                .disabled(viewModel.isRunning)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.transferPolicy.ruleDescriptors) { rule in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(rule.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !viewModel.transferPolicy.ignoredCustomRules.isEmpty {
                        Divider()
                        ForEach(viewModel.transferPolicy.ignoredCustomRules, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 360, alignment: .leading)

            GroupBox("Copy Priority") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: $viewModel.priorityMode) {
                        ForEach(TransferPriorityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isRunning)

                    Text(viewModel.priorityPolicy.mode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Priority never excludes data. Transfer Scope still decides what is included; priority only changes what gets copied first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.priorityPolicy.ruleDescriptors) { rule in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(rule.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(width: 360, alignment: .leading)
            }

            GroupBox("Controls") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("Workers: \(viewModel.workerCount)", value: $viewModel.workerCount, in: 2...6)
                        .disabled(viewModel.isRunning)
                    Stepper("Hydration Window: \(viewModel.hydrationWindow)", value: $viewModel.hydrationWindow, in: 4...24)
                        .disabled(viewModel.isRunning)
                    Stepper("Retries: \(viewModel.retryCount)", value: $viewModel.retryCount, in: 1...6)
                        .disabled(viewModel.isRunning)
                    Text("Hydration Window controls how many iCloud placeholders each worker may actively trigger and poll in parallel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Start") { viewModel.start() }
                            .disabled(!viewModel.canStart)
                        Button(viewModel.isPaused ? "Resume" : "Pause") { viewModel.pauseOrResume() }
                            .disabled(!viewModel.isRunning)
                        Button("Cancel") { viewModel.cancel() }
                            .disabled(!viewModel.isRunning)
                    }
                    Button("Export Log") { viewModel.exportLog() }
                        .disabled(viewModel.logs.isEmpty)
                    if let error = viewModel.errorText {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 360, alignment: .leading)
            }
        }
    }

    private var batchQueueSection: some View {
        GroupBox("Batch Queue") {
            VStack(alignment: .leading, spacing: 14) {
                batchMetricsGrid

                if let sourceURL = viewModel.sourceURL {
                    Text("Batch ZIP archives are written to \(sourceURL.appendingPathComponent("_Materializer_Archives", isDirectory: true).path)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.batchProjects.isEmpty {
                    Text("Choose a batch source root and destination root to preview the queue of direct subfolders.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.batchProjects) { project in
                                batchProjectRow(project)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220, maxHeight: 320)
                }
            }
        }
    }

    private var liveProgressSection: some View {
        GroupBox("Live Progress") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.snapshot.phase == .scanning || viewModel.snapshot.phase == .planningChunks {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Scanning is still building the full inventory. ETA becomes reliable after the scan is complete.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledProgress(
                            title: "Item Progress",
                            value: itemProgress,
                            summary: "\(viewModel.snapshot.totalCopied + viewModel.snapshot.totalFailed) / \(max(viewModel.snapshot.totalDiscovered, 1))"
                        )
                        labeledProgress(
                            title: "Byte Progress",
                            value: byteProgress,
                            summary: "\(formattedBytes(viewModel.snapshot.copiedBytes)) / \(formattedBytes(viewModel.snapshot.totalExpectedBytes))"
                        )
                    }
                }
            }
        }
    }

    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                GroupBox("Live Workers") {
                    if visibleActivities.isEmpty {
                        Text("No active work yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleActivities) { activity in
                                    workerRow(activity)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 260)

                GroupBox("Failures") {
                    if viewModel.failures.isEmpty {
                        Text("No failures recorded.")
                            .foregroundStyle(.secondary)
                    } else {
                        List(viewModel.failures) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.relativePath)
                                    .font(.system(.body, design: .monospaced))
                                Text("\(failure.reason.rawValue): \(failure.message)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(width: 360)
                .frame(minHeight: 260)
            }

            GroupBox("Event Stream") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.logs) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(timestamp(entry.createdAt))  [\(entry.level.rawValue.uppercased())] \(entry.message)")
                                        .font(.system(.body, design: .monospaced))
                                    if let path = entry.path {
                                        Text(path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .id(entry.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: viewModel.logs.count, initial: false) { _, _ in
                        guard let lastID = viewModel.logs.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
    }

    private var metricsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                metricCard("Discovered", value: "\(viewModel.snapshot.totalDiscovered)")
                metricCard("Downloaded", value: "\(viewModel.snapshot.totalDownloaded)")
                metricCard("Copied", value: "\(viewModel.snapshot.totalCopied)")
                metricCard("Failed", value: "\(viewModel.snapshot.totalFailed)")
            }
            GridRow {
                metricCard("Items/s", value: rateText(viewModel.snapshot.throughputItemsPerSecond))
                metricCard("MiB/s", value: byteRateText(viewModel.snapshot.throughputBytesPerSecond))
                metricCard("ETA", value: etaInlineText)
                metricCard("Active", value: "\(viewModel.snapshot.activeWorkerCount)")
            }
        }
    }

    private var chunkGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                metricCard("Chunks", value: "\(viewModel.snapshot.processedChunks) / \(max(viewModel.snapshot.plannedChunks, viewModel.snapshot.processedChunks))")
                metricCard("Remaining", value: "\(viewModel.snapshot.estimatedRemainingCount)")
                metricCard("Expected Bytes", value: formattedBytes(viewModel.snapshot.totalExpectedBytes))
                metricCard("Copied Bytes", value: formattedBytes(viewModel.snapshot.copiedBytes))
            }
        }
    }

    private var batchMetricsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                metricCard("Projects", value: "\(viewModel.batchSnapshot.totalProjects)")
                metricCard("Done", value: "\(viewModel.batchSnapshot.completedProjects)")
                metricCard("Warnings", value: "\(viewModel.batchSnapshot.warningProjects)")
                metricCard("Conflicts", value: "\(viewModel.batchSnapshot.conflictedProjects)")
            }
            GridRow {
                metricCard("Ready", value: "\(viewModel.batchSnapshot.readyForDeletionProjects)")
                metricCard("Failed", value: "\(viewModel.batchSnapshot.failedProjects)")
                metricCard("Batch", value: viewModel.batchSnapshot.state.rawValue)
                metricCard("Current", value: batchCurrentText)
            }
        }
    }

    private func folderRow(title: String, path: String?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(path ?? "Not selected")
                    .font(.callout)
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Choose", action: action)
        }
    }

    private func labeledProgress(title: String, value: Double, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(summary)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1))
                .controlSize(.large)
        }
    }

    private func workerRow(_ activity: WorkerActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(activity.label)
                    .font(.headline)
                Spacer()
                livePhaseBadge(activity.phase)
            }
            Text(activity.detail)
                .font(.subheadline)
            if let path = activity.path {
                Text(path)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batchProjectRow(_ project: BatchProjectPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.sourceFolderName)
                        .font(.headline)
                    Text(project.targetFolderName)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                batchStateBadge(project.state)
            }
            Text(project.sourceURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            if let detail = project.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(project.state == .failed || project.state == .conflicted ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if project.readyForDeletion {
                Text("Ready for source deletion review")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if let archiveURL = project.archiveURL {
                Text("Archive: \(archiveURL.path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            if let manifestURL = project.deletionManifestURL, project.readyForDeletion {
                Text("Manifest: \(manifestURL.path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseBadge(for phase: JobPhase) -> some View {
        Text(phase.rawValue)
            .font(.system(.headline, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(phaseColor(for: phase).opacity(0.16), in: Capsule())
            .foregroundStyle(phaseColor(for: phase))
    }

    private func livePhaseBadge(_ phase: LiveActivityPhase) -> some View {
        Text(phase.rawValue)
            .font(.system(.caption, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(livePhaseColor(for: phase).opacity(0.14), in: Capsule())
            .foregroundStyle(livePhaseColor(for: phase))
    }

    private func batchStateBadge(_ state: BatchProjectState) -> some View {
        Text(state.rawValue)
            .font(.system(.caption, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(batchStateColor(for: state).opacity(0.14), in: Capsule())
            .foregroundStyle(batchStateColor(for: state))
    }

    private var visibleActivities: [WorkerActivity] {
        if !viewModel.activities.isEmpty {
            return viewModel.activities
        }
        guard viewModel.isRunning else { return [] }
        return [
            WorkerActivity(
                id: viewModel.snapshot.jobID,
                label: "Coordinator",
                phase: livePhase(from: viewModel.snapshot.phase),
                detail: viewModel.snapshot.phaseDetail ?? "Working",
                path: viewModel.snapshot.currentPath,
                updatedAt: Date()
            )
        ]
    }

    private var itemProgress: Double {
        guard viewModel.snapshot.totalDiscovered > 0 else { return 0 }
        return Double(viewModel.snapshot.totalCopied + viewModel.snapshot.totalFailed) / Double(viewModel.snapshot.totalDiscovered)
    }

    private var byteProgress: Double {
        guard viewModel.snapshot.totalExpectedBytes > 0 else { return 0 }
        return Double(viewModel.snapshot.copiedBytes) / Double(viewModel.snapshot.totalExpectedBytes)
    }

    private var etaText: String {
        if viewModel.snapshot.phase == .scanning || viewModel.snapshot.phase == .planningChunks {
            return "ETA after scan"
        }
        guard let seconds = viewModel.snapshot.estimatedRemainingSeconds else {
            return "ETA calculating"
        }
        return "ETA \(formattedDuration(seconds))"
    }

    private var etaInlineText: String {
        if viewModel.snapshot.phase == .scanning || viewModel.snapshot.phase == .planningChunks {
            return "After scan"
        }
        guard let seconds = viewModel.snapshot.estimatedRemainingSeconds else {
            return "Calculating"
        }
        return formattedDuration(seconds)
    }

    private var batchCurrentText: String {
        guard
            let index = viewModel.batchSnapshot.currentProjectIndex,
            let name = viewModel.batchSnapshot.currentProjectName
        else {
            return "-"
        }
        return "\(index)/\(max(viewModel.batchSnapshot.totalProjects, index)) \(name)"
    }

    private var batchSuffixPreviewText: String {
        let trimmed = viewModel.batchSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix: String
        if trimmed.isEmpty {
            suffix = ""
        } else if trimmed.hasPrefix("-") || trimmed.hasPrefix("_") || trimmed.hasPrefix(" ") {
            suffix = trimmed
        } else {
            suffix = "-\(trimmed)"
        }
        return "Each direct subfolder becomes its own project run. Targets are created under the destination root as `<name>\(suffix)` unless you already include your own leading separator."
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "Calculating" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter.string(from: max(seconds, 0)) ?? "0s"
    }

    private func rateText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func byteRateText(_ value: Double) -> String {
        let mebibytesPerSecond = value / (1024 * 1024)
        return String(format: "%.2f", mebibytesPerSecond)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func phaseColor(for phase: JobPhase) -> Color {
        switch phase {
        case .completed:
            return .green
        case .completedWithWarnings:
            return .orange
        case .failed, .cancelled:
            return .red
        case .zipping:
            return .blue
        default:
            return .accentColor
        }
    }

    private func batchStateColor(for state: BatchProjectState) -> Color {
        switch state {
        case .completed:
            return .green
        case .completedWithWarnings, .conflicted:
            return .orange
        case .failed, .cancelled:
            return .red
        case .running:
            return .blue
        case .pending:
            return .secondary
        }
    }

    private func livePhaseColor(for phase: LiveActivityPhase) -> Color {
        switch phase {
        case .scanning:
            return .teal
        case .planning:
            return .mint
        case .materializing:
            return .blue
        case .copying:
            return .orange
        case .verifying:
            return .indigo
        case .promoting:
            return .green
        case .zipping:
            return .pink
        case .idle:
            return .secondary
        }
    }

    private func livePhase(from phase: JobPhase) -> LiveActivityPhase {
        switch phase {
        case .scanning:
            return .scanning
        case .planningChunks:
            return .planning
        case .materializing:
            return .materializing
        case .copying:
            return .copying
        case .verifyingChunks, .finalVerifying:
            return .verifying
        case .promoting:
            return .promoting
        case .zipping:
            return .zipping
        default:
            return .idle
        }
    }
}
