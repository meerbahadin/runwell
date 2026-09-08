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
    @State private var breakdown: HistoryStore.EnergyBreakdown?
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
                } else if battery.isEmpty && (breakdown?.rows.isEmpty ?? true) {
                    noDataYet
                } else {
                    headline
                    Divider()
                    batteryChart
                    Divider()
                    consumersSection
                    Divider()
                    sessionsSection
                    footnote
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
        breakdown = try? await store.energyBreakdown(
            from: from, to: to, granularity: range.granularity, limit: 8)
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

    // MARK: - Headline

    /// The plain-language answer, before any chart. Someone should be able to read
    /// this one line and stop, without decoding a unit or a bar length.
    @ViewBuilder
    private var headline: some View {
        let drop = batteryDrop
        VStack(alignment: .leading, spacing: 6) {
            if let top = breakdown?.rows.first, let share = breakdown?.share(of: top), share > 0 {
                Text(headlineText(top: top, share: share, drop: drop))
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let drop, drop > 0 {
                Text("Your battery went down \(Int(drop))% in the last \(range.rawValue.lowercased()).")
                    .font(.title3)
            } else {
                Text("Nothing has used a noticeable amount of energy in the last \(range.rawValue.lowercased()).")
                    .font(.title3)
            }
        }
    }

    private func headlineText(top: HistoryStore.BucketRow, share: Double, drop: Double?) -> String {
        let percent = Int((share * 100).rounded())
        if let drop, drop > 0 {
            return "Your battery went down \(Int(drop))% in the last \(range.rawValue.lowercased()). \(top.displayName) used the most energy of the apps we could measure — about \(percent)% of it."
        }
        return "\(top.displayName) used the most energy in the last \(range.rawValue.lowercased()) — about \(percent)% of everything we could measure."
    }

    /// Percentage points lost across the window, counting only time on battery so
    /// that a charge in the middle does not read as negative use.
    private var batteryDrop: Double? {
        let discharging = battery.filter { $0.onBattery && !$0.isCharging }
        guard let first = discharging.first?.percentage,
              let last = discharging.last?.percentage, first > last else { return nil }
        return first - last
    }

    // MARK: - Battery

    @ViewBuilder
    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery level").font(.headline)
                Spacer()
                if let drop = batteryDrop, drop > 0 {
                    Text("Down \(Int(drop))%")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }

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
            Text("Time on battery").font(.headline)
            if sessions.isEmpty {
                Text("Your Mac has been plugged in for this whole period.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    HStack(spacing: 12) {
                        Image(systemName: "battery.50")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))")
                            Text(sessionSummary(session))
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

    /// Reads as a sentence, and adds the rate only once there is enough of a run for
    /// an extrapolation to mean anything.
    private func sessionSummary(_ session: HistoryStore.BatterySession) -> String {
        let used = Int(session.percentageUsed)
        let duration = durationText(session.duration)
        guard used > 0, session.duration >= 600 else {
            return used > 0 ? "Used \(used)% over \(duration)" : "On battery for \(duration)"
        }
        let perHour = session.percentageUsed / (session.duration / 3600)
        return "Used \(used)% over \(duration) — about \(Int(perHour))% per hour at that rate"
    }

    // MARK: - Consumers

    @ViewBuilder
    private var consumersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What used the most energy").font(.headline)

            if let breakdown, !breakdown.rows.isEmpty, breakdown.totalEnergyNJ > 0 {
                ForEach(breakdown.rows) { row in
                    consumerRow(row, share: breakdown.share(of: row))
                }
            } else {
                Text("Nothing measurable yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// One app: name, share of measured energy as both a bar and a percentage, and a
    /// familiar comparison. No joules — the unit meant nothing to most readers, and a
    /// raw total is unreadable anyway without knowing the window it covers.
    private func consumerRow(_ row: HistoryStore.BucketRow, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayName).lineLimit(1)
                if row.confidence < 0.7 {
                    // Section 3: an incomplete total says so rather than passing as
                    // whole. The threshold sits below the 0.85 a fully readable energy
                    // counter carries, so this marks genuinely partial coverage rather
                    // than firing on every row and becoming noise.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("Some processes in this app could not be read, so this is a partial total.")
                }
                Spacer()
                Text("\(Int((share * 100).rounded()))%")
                    .monospacedDigit().fontWeight(.medium)
            }

            // Section 8.5: never severity by colour alone — the percentage above and
            // the description below both carry the same information as the bar.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary.opacity(0.5))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.blue.gradient)
                        .frame(width: max(2, geometry.size.width * share))
                }
            }
            .frame(height: 8)

            Text(comparison(row))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayName), \(Int((share * 100).rounded())) percent of measured energy. \(comparison(row))")
    }

    /// Translates average power into something recognisable. Watts are the unit people
    /// already read off appliances, and the phrasing stays comparative rather than
    /// claiming a share of the battery pack, which Section 3.1 forbids.
    private func comparison(_ row: HistoryStore.BucketRow) -> String {
        let watts = row.averageWatts
        let level: String
        switch watts {
        case ..<0.05:  level = "barely any power"
        case ..<0.25:  level = "a little power"
        case ..<1.0:   level = "a moderate amount of power"
        case ..<3.0:   level = "a lot of power"
        default:       level = "a very large amount of power"
        }
        let minutes = Int(row.observedSeconds / 60)
        let watched = minutes >= 1 ? " over \(minutes) min watched" : ""
        return "Used \(level) on average\(watched) — \(String(format: "%.2f W", watts))."
    }

    // MARK: - Footnote

    /// Section 3.1: the honest caveat, stated once at the bottom in plain words
    /// instead of hedging every number above it.
    private var footnote: some View {
        Text("These shares compare apps with each other. They do not add up to your whole battery — the screen, Wi-Fi and macOS itself also use power, and PowerTask cannot measure every process.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}
