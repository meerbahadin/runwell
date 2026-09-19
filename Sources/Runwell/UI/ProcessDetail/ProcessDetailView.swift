import SwiftUI
import RunwellKit

/// Section 8.1. Group total, child processes, provenance, explanation and actions.
struct ProcessDetailView: View {
    let group: ApplicationGroup
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingForceQuit: ProcessIntervalMetrics?
    @State private var confirmingGroupForceQuit = false
    @State private var actionError: String?
    @State private var groupOutcome: ProcessActionService.GroupOutcome?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                metricsGrid
                Divider()
                processList
                Divider()
                actionsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(group.displayName)
        .alert("Force quit \(confirmingForceQuit?.identity.name ?? "")?",
               isPresented: .init(
                get: { confirmingForceQuit != nil },
                set: { if !$0 { confirmingForceQuit = nil } }
               ), presenting: confirmingForceQuit) { target in
            // Section 8.4: force quit is never the default action.
            Button("Cancel", role: .cancel) { confirmingForceQuit = nil }
            Button("Force Quit", role: .destructive) { forceQuit(target) }
        } message: { target in
            Text("\(target.identity.name) will quit immediately and any unsaved work will be lost.")
        }
        .alert("Action failed", isPresented: .init(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        // Section 8.4: force quit is never a default, and a group action must name
        // how many processes it will kill before the user commits to it.
        .alert("Force quit \(quittableCount) processes in \(group.displayName)?",
               isPresented: $confirmingGroupForceQuit) {
            Button("Cancel", role: .cancel) { confirmingGroupForceQuit = false }
            Button("Force Quit All", role: .destructive) {
                groupOutcome = environment.actions.forceQuitGroup(group, userConfirmed: true)
            }
        } message: {
            Text(groupConfirmationMessage)
        }
        .alert("Quit \(group.displayName)", isPresented: .init(
            get: { groupOutcome != nil },
            set: { if !$0 { groupOutcome = nil } }
        ), presenting: groupOutcome) { _ in
            Button("OK", role: .cancel) { groupOutcome = nil }
        } message: { outcome in
            Text(outcomeMessage(outcome))
        }
    }

    /// How many of the group's processes the policy will actually allow us to touch.
    /// Section 9.2: a protected process is never terminated as part of a group action.
    private var quittableCount: Int {
        group.members.filter { !environment.actions.protection(for: $0.identity).isBlocked }.count
    }

    private var groupConfirmationMessage: String {
        var text = "Every process in this application will quit immediately and any unsaved work will be lost."
        let blocked = group.members.count - quittableCount
        if blocked > 0 {
            // Say what will survive, so the result is never a surprise.
            text += " \(blocked) protected process\(blocked == 1 ? "" : "es") will be left running."
        }
        return text
    }

    /// Reports per-process reality rather than a blanket "done".
    private func outcomeMessage(_ outcome: ProcessActionService.GroupOutcome) -> String {
        var parts: [String] = []
        if outcome.terminated.isEmpty {
            parts.append("No processes were quit.")
        } else {
            parts.append("Quit \(outcome.terminated.count) process\(outcome.terminated.count == 1 ? "" : "es").")
        }
        if outcome.alreadyGone > 0 {
            parts.append("\(outcome.alreadyGone) had already exited.")
        }
        if !outcome.skipped.isEmpty {
            parts.append("Left running (protected): \(outcome.skipped.map(\.name).joined(separator: ", ")).")
        }
        if !outcome.failed.isEmpty {
            parts.append("Did not quit: \(outcome.failed.map(\.name).joined(separator: ", ")).")
        }
        return parts.joined(separator: "\n")
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(bundleURL: group.bundleURL, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.displayName).font(.title2.weight(.medium))
                Text("\(group.processCount) process\(group.processCount == 1 ? "" : "es")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: group.status)
        }
    }

    private var metricsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                metricCell("Energy", MetricText(metric: group.totalEnergyWatts, format: "%.2f", suffix: " W"))
                metricCell("CPU", MetricText(
                    metric: displayCPU(group.totalCPUPercent, normalize: environment.normalizeCPU,
                                       coreCount: environment.capabilities.logicalProcessorCount),
                    format: "%.1f", suffix: "%"
                ))
            }
            GridRow {
                metricCell("Memory", MemoryText(metric: group.totalFootprintBytes))
                metricCell("Disk", MetricText(metric: group.totalDiskBytesPerSecond.map { $0 / 1_048_576 },
                                              format: "%.2f", suffix: " MB/s"))
            }
            if let share = environment.snapshot?.coverage.measuredAppShare(of: group) {
                GridRow {
                    // Section 3.1: this exact wording, never "battery percentage used".
                    metricCell(EnergyCoverage.shareLabel,
                               MetricText(metric: share.map { $0 * 100 }, format: "%.1f", suffix: "%"))
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func metricCell(_ title: String, _ content: some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Typography.caption).foregroundStyle(.secondary)
            // The badge beside every number was more clutter than information: it
            // repeated on each cell and said "Derived" about values that are always
            // derived. Provenance still governs what is shown — an unavailable
            // reading is an em dash, never a zero — and Diagnostics reports each
            // collector's provenance in full.
            content.font(Theme.Typography.title)
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processes").font(Theme.Typography.headline)
            // Section 6: grouping is reversible and explainable here.
            ForEach(group.members, id: \.key) { member in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(member.identity.name).fontWeight(.medium)
                        Text("PID \(member.identity.key.pid)")
                            .font(Theme.Typography.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        MetricText(metric: member.energyWatts, format: "%.2f", suffix: " W")
                            .font(Theme.Typography.callout)
                        MetricText(
                            metric: displayCPU(member.cpuPercent, normalize: environment.normalizeCPU,
                                               coreCount: environment.capabilities.logicalProcessorCount),
                            format: "%.1f", suffix: "%"
                        )
                            .font(Theme.Typography.callout).frame(width: 60, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text(member.identity.groupingReason.explanation)
                            .font(Theme.Typography.caption).foregroundStyle(.secondary)
                        Spacer()
                        processActions(for: member)
                    }
                }
                .cardSurface()
            }
        }
    }

    @ViewBuilder
    private func processActions(for member: ProcessIntervalMetrics) -> some View {
        let protection = environment.actions.protection(for: member.identity)
        HStack(spacing: 8) {
            switch protection {
            case .blocked(let reason):
                // Section 8.4 / 9.2: protected processes are not offered at all, and
                // the UI says why rather than silently disabling a button.
                Label("Protected", systemImage: "lock.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .help(reason)
            case .requiresConfirmation(let reason):
                Button("Quit") { quit(member) }
                    .controlSize(.small)
                    .help(reason)
                Button("Force Quit") { confirmingForceQuit = member }
                    .controlSize(.small)
                    .help(reason)
            case .unprotected:
                Button("Quit") { quit(member) }
                    .controlSize(.small)
                Button("Force Quit") { confirmingForceQuit = member }
                    .controlSize(.small)
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 10) {
            // Group actions only earn their place when there is more than one process;
            // for a single-process group the per-process row buttons already cover it.
            if group.members.count > 1 {
                Button {
                    groupOutcome = environment.actions.quitGroup(group)
                } label: {
                    Label("Quit All", systemImage: "xmark.circle")
                }
                .disabled(quittableCount == 0)
                .help("Sends a normal quit request to all \(quittableCount) permitted processes in this application.")

                Button {
                    confirmingGroupForceQuit = true
                } label: {
                    Label("Force Quit All", systemImage: "exclamationmark.octagon")
                }
                .disabled(quittableCount == 0)
                .help("Immediately terminates all \(quittableCount) permitted processes. Unsaved work will be lost.")

                Divider().frame(height: 16)
            }

            Button {
                if case .failure(let error) = environment.actions.revealInFinder(
                    identity: group.members[0].identity
                ) {
                    actionError = error.errorDescription
                }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(group.bundleURL == nil && group.members.first?.identity.executable == nil)

            Button {
                guard let coverage = environment.snapshot?.coverage else { return }
                // Section 8.4 / 9.1: a privacy-reviewed summary — redacted paths and
                // no command-line arguments.
                let summary = environment.actions.diagnosticSummary(for: group, coverage: coverage)
                environment.actions.copyToPasteboard(summary)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Details", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copies a diagnostic summary with home-directory names removed and no command-line arguments.")

            Spacer()
        }
    }

    private func quit(_ member: ProcessIntervalMetrics) {
        if case .failure(let error) = environment.actions.quit(identity: member.identity) {
            actionError = error.errorDescription
        }
    }

    private func forceQuit(_ member: ProcessIntervalMetrics) {
        confirmingForceQuit = nil
        if case .failure(let error) = environment.actions.forceQuit(
            identity: member.identity, userConfirmed: true
        ) {
            actionError = error.errorDescription
        }
    }
}
