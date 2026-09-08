import SwiftUI
import Charts
import PowerTaskKit

/// Section 8.1. Battery level, process energy and memory over time, with session
/// markers — the surface that answers "what drained my battery earlier?", which the
/// live table structurally cannot.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var range: Range = .sixHours
    @State private var battery: [HistoryStore.BatteryPoint] = []
    @State private var consumers: [HistoryStore.BucketRow] = []
    @State private var sessions: [HistoryStore.BatterySession] = []
    @State private var isLoading = true

    enum Range: String, CaseIterable, Identifiable {
        case oneHour = "1 hour"
        case sixHours = "6 hours"
        case day = "24 hours"
        case week = "7 days"
        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .oneHour: 3_600
            case .sixHours: 21_600
            case .day: 86_400
            case .week: 604_800
            }
        }

        /// Section 7.2: only the 15-minute tier reaches back beyond seven days.
        var granularity: String { self == .week ? "15m" : "1m" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if environment.history == nil {
                    historyDisabled
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if battery.isEmpty && consumers.isEmpty {
                    noDataYet
                } else {
                    batteryChart
                    Divider()
                    sessionsSection
                    Divider()
                    consumersSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: range) { await load() }
        // Refresh as new samples land, without hammering the database every cycle.
        .task(id: range) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await load()
            }
        }
    }

    private func load() async {
        guard let store = environment.history else { isLoading = false; return }
        let to = Date()
        let from = to.addingTimeInterval(-range.seconds)
        battery = (try? await store.batteryHistory(from: from, to: to)) ?? []
        consumers = (try? await store.topEnergyConsumers(
            from: from, to: to, granularity: range.granularity, limit: 12)) ?? []
        sessions = (try? await store.batterySessions(from: from, to: to)) ?? []
        isLoading = false
    }

    // MARK: - Empty states

    private var historyDisabled: some View {
        ContentUnavailableView {
            Label("History is off", systemImage: "clock.badge.xmark")
        } description: {
            Text("Turn history on in Settings to record battery use over time. Live monitoring works either way.")
        }
    }

    private var noDataYet: some View {
        ContentUnavailableView {
            Label("No history yet", systemImage: "clock")
        } description: {
            Text("PowerTask records a sample every cycle while it is running. Come back in a few minutes.")
        }
    }

    // MARK: - Battery

    @ViewBuilder
    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery level").font(.headline)

            let points = battery.compactMap { point -> (Date, Double, Bool)? in
                guard let percentage = point.percentage else { return nil }
                return (point.timestamp, percentage, point.onBattery)
            }

            if points.isEmpty {
                Text("No battery readings in this range.")
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        AreaMark(x: .value("Time", point.0), y: .value("Charge", point.1))
                            .foregroundStyle(.blue.opacity(0.15))
                        LineMark(x: .value("Time", point.0), y: .value("Charge", point.1))
                            .foregroundStyle(.blue)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
                .frame(height: 160)
                // Section 8.5: charts expose a textual alternative.
                .accessibilityLabel(batteryAccessibilitySummary(points))
            }
        }
    }

    private func batteryAccessibilitySummary(_ points: [(Date, Double, Bool)]) -> String {
        guard let first = points.first, let last = points.last else { return "No data" }
        return "Battery went from \(Int(first.1))% to \(Int(last.1))% over \(range.rawValue)."
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery sessions").font(.headline)
            if sessions.isEmpty {
                Text("No time on battery in this range.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    HStack(spacing: 12) {
                        Image(systemName: "battery.50")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))")
                            Text("\(Int(session.percentageUsed))% used over \(durationText(session.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: - Consumers

    @ViewBuilder
    private var consumersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measured energy by application").font(.headline)
            // Section 3.1: this is a share of what PowerTask could measure, never a
            // claim about the whole battery.
            Text("Totals cover the processes PowerTask was allowed to read while it was running.")
                .font(.caption).foregroundStyle(.secondary)

            if consumers.isEmpty {
                Text("No measured energy in this range.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(consumers) { row in
                    BarMark(
                        x: .value("Energy", row.energyJoules),
                        y: .value("App", row.displayName)
                    )
                    .foregroundStyle(.blue.gradient)
                }
                .chartXAxisLabel("Joules")
                .frame(height: CGFloat(consumers.count) * 28 + 40)

                ForEach(consumers) { row in
                    HStack {
                        Text(row.displayName).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f J", row.energyJoules))
                            .monospacedDigit().foregroundStyle(.secondary)
                        // Section 3: coverage confidence travels with the number.
                        if row.confidence < 0.9 {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("Some processes in this group were not readable, so this total is partial.")
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }
}
