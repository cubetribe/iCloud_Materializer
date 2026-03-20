import SwiftUI

struct MainView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Folders") {
                VStack(alignment: .leading, spacing: 10) {
                    folderRow(title: "Source", path: viewModel.sourceURL?.path) {
                        viewModel.chooseSourceFolder()
                    }
                    folderRow(title: "Destination", path: viewModel.destinationURL?.path) {
                        viewModel.chooseDestinationFolder()
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                GroupBox("Summary") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        summaryRow("Phase", value: viewModel.snapshot.phase.rawValue)
                        summaryRow("Discovered", value: "\(viewModel.snapshot.totalDiscovered)")
                        summaryRow("Downloaded", value: "\(viewModel.snapshot.totalDownloaded)")
                        summaryRow("Copied", value: "\(viewModel.snapshot.totalCopied)")
                        summaryRow("Failed", value: "\(viewModel.snapshot.totalFailed)")
                        summaryRow("Throughput", value: String(format: "%.2f items/s", viewModel.snapshot.throughputItemsPerSecond))
                        summaryRow("Remaining", value: "\(viewModel.snapshot.estimatedRemainingCount)")
                        summaryRow("Current", value: viewModel.snapshot.currentPath ?? "Idle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Workers: \(viewModel.workerCount)", value: $viewModel.workerCount, in: 2...6)
                        Stepper("Retries: \(viewModel.retryCount)", value: $viewModel.retryCount, in: 1...6)
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
                        if let error = viewModel.snapshot.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Live Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.logs) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                                    .font(.system(.body, design: .monospaced))
                                if let path = entry.path {
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 240)
            }

            GroupBox("Failed Items") {
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
                    .frame(minHeight: 160)
                }
            }
        }
        .padding(20)
        .frame(width: 1040, height: 880)
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

    private func summaryRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}
