import SwiftUI
import RunwellKit

/// Section 10.3. A local diagnostics page showing collector health without requiring
/// remote telemetry. Appendix F: the OS build and hardware identifier are recorded
/// here for local troubleshooting and never sent anywhere.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                system
                Divider()
                collectors
                Divider()
                sampling
                Divider()
                actions
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Diagnostics")
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("macOS build").foregroundStyle(.secondary)
                    Text(environment.capabilities.osBuild).monospaced()
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(environment.capabilities.hardwareModel).monospaced()
                }
                GridRow {
                    Text("Logical cores").foregroundStyle(.secondary)
                    Text("\(environment.capabilities.logicalProcessorCount)").monospacedDigit()
                }
                GridRow {
                    Text("Battery").foregroundStyle(.secondary)
                    Text(environment.capabilities.hasBattery ? "Present" : "None — resource-monitor mode")
                }
            }
            .font(.callout)
        }
    }

    /// The collector-health table. Section 10.2: a collector that fails is disabled
    /// independently and shows a visible reason rather than silently reporting zero.
    private var collectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Collectors").font(.headline)
            ForEach(Collector.allCases, id: \.self) { collector in
                if let status = environment.capabilities.status(collector) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // Section 8.5: never encode state with colour alone.
                        Image(systemName: status.available ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(status.available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(collector.displayName).fontWeight(.medium)
                                ProvenanceBadge(provenance: status.provenance, compact: true)
                            }
                            Text(status.reason)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .cardSurface()
                }
            }
        }
    }

    private var sampling: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sampler").font(.headline)
            if let snapshot = environment.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Mode").foregroundStyle(.secondary)
                        Text(snapshot.mode.description)
                    }
                    GridRow {
                        Text("Last cycle").foregroundStyle(.secondary)
                        // Section 10.1 budget: p95 collection under 25% of the interval.
                        let ms = Double(snapshot.cycleDuration.components.attoseconds) / 1e15
                            + Double(snapshot.cycleDuration.components.seconds) * 1000
                        Text(String(format: "%.0f ms of %.0f ms budget", ms,
                                    snapshot.mode.intervalSeconds * 250))
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Skipped cycles").foregroundStyle(.secondary)
                        // Section 10.2: a cycle is skipped rather than overlapped.
                        Text("\(snapshot.skippedCycles)").monospacedDigit()
                    }
                    GridRow {
                        Text("Groups").foregroundStyle(.secondary)
                        Text("\(snapshot.groups.count)").monospacedDigit()
                    }
                    GridRow {
                        Text("Unreadable processes").foregroundStyle(.secondary)
                        Text("\(snapshot.coverage.inaccessibleProcessCount)").monospacedDigit()
                    }
                }
                .font(.callout)
            } else {
                Text("Waiting for the first sample…").foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Report").font(.headline)
            Text("Copies the values on this page. Section 9.1: no process list, paths or command lines are included.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                environment.actions.copyToPasteboard(report)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }

    /// A redacted health report: capability state only, no process information.
    private var report: String {
        var lines = ["Runwell diagnostics"]
        lines.append("macOS build: \(environment.capabilities.osBuild)")
        lines.append("Model: \(environment.capabilities.hardwareModel)")
        lines.append("Cores: \(environment.capabilities.logicalProcessorCount)")
        lines.append("")
        lines.append("Collectors:")
        for collector in Collector.allCases {
            if let status = environment.capabilities.status(collector) {
                lines.append("  \(collector.displayName): \(status.available ? "available" : "unavailable") — \(status.reason)")
            }
        }
        if let snapshot = environment.snapshot {
            lines.append("")
            lines.append("Sampler: \(snapshot.mode.description), \(snapshot.groups.count) groups, \(snapshot.skippedCycles) skipped cycles")
        }
        return lines.joined(separator: "\n")
    }
}
