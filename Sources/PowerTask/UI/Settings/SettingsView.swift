import SwiftUI
import PowerTaskKit

/// Section 8.1. Sampling, retention, display conventions and privacy.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var statistics: HistoryStore.Statistics?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var environment = environment

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sampling(environment: environment)
                Divider()
                display(environment: environment)
                Divider()
                historySection(environment: environment)
                Divider()
                privacy
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .task { statistics = await environment.historyStatistics() }
        .alert("Delete all history?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) { confirmingClear = false }
            Button("Delete", role: .destructive) {
                Task {
                    await environment.clearHistory()
                    statistics = await environment.historyStatistics()
                }
            }
        } message: {
            Text("Every recorded sample is removed from this Mac. Live monitoring keeps working.")
        }
    }

    // MARK: - Sampling

    private func sampling(environment: AppEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sampling").font(.headline)
            // Section 5.1: a longer interval means less observer effect, which is the
            // Section 1.3 principle that the monitor must not itself drain the battery.
            Picker("Interval", selection: Binding(
                get: { environment.samplingMode },
                set: { environment.setMode($0) }
            )) {
                ForEach([SamplingMode.foreground, .menuBarOnly, .batteryIdle, .lowPowerMode], id: \.self) { mode in
                    Text(mode.description).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text("A shorter interval updates sooner and costs slightly more energy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Display

    private func display(environment: AppEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Display").font(.headline)
            // Section 5.3: the default is raw macOS-style percentage, which may exceed
            // 100% for a multithreaded process; a setting switches to normalized.
            Toggle("Show CPU as a share of all cores (0–100%)", isOn: Binding(
                get: { environment.normalizeCPU },
                set: { environment.normalizeCPU = $0 }
            ))
            Text(environment.normalizeCPU
                 ? "A process using every core reads as 100%."
                 : "Matches Activity Monitor: a process using four cores reads as 400%.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - History

    private func historySection(environment: AppEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.headline)

            // Section 7.2 / 9.1: history is optional and can be cleared at any time.
            Toggle("Record history on this Mac", isOn: Binding(
                get: { environment.isHistoryEnabled },
                set: { environment.isHistoryEnabled = $0 }
            ))

            Text("Samples stay on this Mac. Nothing is uploaded.")
                .font(.caption).foregroundStyle(.secondary)

            if let error = environment.historyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let statistics {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Applications recorded").foregroundStyle(.secondary)
                        Text("\(statistics.applications)").monospacedDigit()
                    }
                    GridRow {
                        Text("Stored rows").foregroundStyle(.secondary)
                        Text("\(statistics.bucketRows)").monospacedDigit()
                    }
                    GridRow {
                        Text("Database size").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: statistics.fileSizeBytes, countStyle: .file))
                            .monospacedDigit()
                    }
                    if let earliest = statistics.earliest {
                        GridRow {
                            Text("Oldest sample").foregroundStyle(.secondary)
                            Text(earliest.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                .font(.callout)
            }

            // Section 7.2 retention tiers, stated rather than buried.
            Text("Raw samples are kept for 2 hours, per-minute totals for 7 days and 15-minute totals for 90 days.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Delete All History…", role: .destructive) { confirmingClear = true }
                .disabled(environment.history == nil)
        }
    }

    // MARK: - Privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy").font(.headline)
            // Section 9.1, stated plainly because it is a product promise.
            ForEach([
                "No account, analytics or advertising.",
                "No outbound network requests.",
                "Command-line arguments are never collected.",
                "Home directory names are removed from stored paths and exports.",
            ], id: \.self) { line in
                Label(line, systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
