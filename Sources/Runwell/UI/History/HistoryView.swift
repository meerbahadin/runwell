import SwiftUI
import Charts
import RunwellKit

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

    /// One plotted battery reading. A named type rather than a tuple: the chart
    /// builder could not type-check the tuple form in reasonable time.
    struct ChartPoint {
        let time: Date
        let percentage: Double
        let onBattery: Bool
    }

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
                    // The headline is the answer; everything below is the evidence
                    // for it, so it leads and the range that scopes it sits with it
                    // rather than in a toolbar the eye never connects to the text.
                    headline
                    rangePicker
                    batteryChart
                    consumersSection
                    sessionsSection
                    footnote
                }
            }
            .padding(Theme.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("History")
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

    // MARK: - Range

    /// Sits under the headline rather than in the toolbar: it scopes every number on
    /// the page, and a control that far from its effect reads as window chrome.
    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Time range")
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
            Text("Runwell records a sample every cycle while it is running. Come back in a few minutes.")
        }
    }

    // MARK: - Headline

    /// The plain-language answer, before any chart. Someone should be able to read
    /// this one line and stop, without decoding a unit or a bar length.
    @ViewBuilder
    private var headline: some View {
        let drop = batteryDrop
        VStack(alignment: .leading, spacing: Theme.Spacing.tight + 2) {
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
        .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.row + 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery level").font(.title3.weight(.semibold))
                Spacer()
                if let drop = batteryDrop, drop > 0 {
                    Text("Down \(Int(drop))%")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            let points = smoothed(battery.compactMap { point -> ChartPoint? in
                guard let percentage = point.percentage else { return nil }
                return ChartPoint(time: point.timestamp, percentage: percentage,
                                  onBattery: point.onBattery)
            })

            if points.isEmpty {
                Text("No battery readings in this range.")
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    chargingBands(points)
                    batteryCurve(points)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let percent = value.as(Int.self) { Text("\(percent)%") }
                        }
                    }
                }
                .chartXAxis { AxisMarks(preset: .aligned) }
                .frame(height: 170)
                // Section 8.5: charts expose a textual alternative.
                // The spoken summary reports what the system actually reported,
                // not the smoothed curve drawn above it.
                .accessibilityLabel(batteryAccessibilitySummary(rawChartPoints))
            }
        }
    }

    /// Charging stretches, shaded behind the line: a rise in the curve otherwise
    /// looks like the battery gaining charge for no reason.
    @ChartContentBuilder
    private func chargingBands(_ points: [ChartPoint]) -> some ChartContent {
        ForEach(chargingSpans(points), id: \.start) { span in
            RectangleMark(
                xStart: .value("From", span.start),
                xEnd: .value("To", span.end),
                yStart: .value("Low", 0),
                yEnd: .value("High", 100)
            )
            .foregroundStyle(.green.opacity(0.10))
        }
    }

    @ChartContentBuilder
    private func batteryCurve(_ points: [ChartPoint]) -> some ChartContent {
        ForEach(points, id: \.time) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Charge", point.percentage))
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue.opacity(0.28), .blue.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.time), y: .value("Charge", point.percentage))
                .foregroundStyle(.blue)
                .lineStyle(.init(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
    }

    /// The unsmoothed readings, for anything that states a number rather than
    /// drawing one.
    private var rawChartPoints: [ChartPoint] {
        battery.compactMap { point in
            guard let percentage = point.percentage else { return nil }
            return ChartPoint(time: point.timestamp, percentage: percentage,
                              onBattery: point.onBattery)
        }
    }

    /// macOS reports charge as whole integers, so the raw series is a staircase:
    /// dozens of identical readings, then a 1% step. Interpolation cannot smooth
    /// that — the flat runs are real — so the curve is averaged over a short
    /// trailing window instead.
    ///
    /// This is a presentational smoothing of a measured value, so it stays here in
    /// the view rather than in the collector: the stored history keeps the integers
    /// the system actually reported (Section 3).
    private func smoothed(_ points: [ChartPoint]) -> [ChartPoint] {
        // Enough of a window to cross a step, small enough not to lag a real drop.
        let window = max(3, min(15, points.count / 20))
        guard points.count > window * 2 else { return points }

        return points.indices.map { index in
            let lower = max(0, index - window / 2)
            let upper = min(points.count - 1, index + window / 2)
            let slice = points[lower...upper]
            let mean = slice.reduce(0.0) { $0 + $1.percentage } / Double(slice.count)
            return ChartPoint(time: points[index].time, percentage: mean,
                              onBattery: points[index].onBattery)
        }
    }

    /// Contiguous runs where the Mac was plugged in, collapsed from per-sample flags
    /// so the chart draws one band per stretch rather than one per reading.
    private func chargingSpans(_ points: [ChartPoint]) -> [(start: Date, end: Date)] {
        var spans: [(start: Date, end: Date)] = []
        var runStart: Date?
        var previous: Date?
        for point in points {
            if !point.onBattery {
                if runStart == nil { runStart = point.time }
                previous = point.time
            } else if let start = runStart, let end = previous {
                spans.append((start, end))
                runStart = nil
                previous = nil
            }
        }
        if let start = runStart, let end = previous { spans.append((start, end)) }
        // A single isolated sample has no width to draw.
        return spans.filter { $0.end > $0.start }
    }

    private func batteryAccessibilitySummary(_ points: [ChartPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "No data" }
        let charging = chargingSpans(points).count
        let plugged = charging > 0
            ? " Plugged in for \(charging) \(charging == 1 ? "period" : "periods")."
            : ""
        return "Battery went from \(Int(first.percentage))% to "
            + "\(Int(last.percentage))% over \(range.rawValue).\(plugged)"
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row + 2) {
            Text("Time on battery").font(.title3.weight(.semibold))
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
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .cardSurface()
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
        VStack(alignment: .leading, spacing: Theme.Spacing.card) {
            HStack(alignment: .firstTextBaseline) {
                Text("What used the most energy").font(.title3.weight(.semibold))
                Spacer()
                if let breakdown, !breakdown.rows.isEmpty {
                    Text("\(breakdown.rows.count) apps")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let breakdown, !breakdown.rows.isEmpty, breakdown.totalEnergyNJ > 0 {
                VStack(alignment: .leading, spacing: Theme.Spacing.card) {
                    ForEach(breakdown.rows) { row in
                        consumerRow(row, share: breakdown.share(of: row))
                    }
                }
                .cardSurface()
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
                AppIconByBundleID(bundleID: row.bundleID, size: 16)
                    // Keep the icon on the text baseline rather than letting it
                    // drag the row's first-baseline alignment upward.
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(row.displayName).lineLimit(1).fontWeight(.medium)
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
                    Capsule().fill(.quaternary.opacity(0.4))
                    Capsule()
                        .fill(.blue.gradient)
                        .frame(width: max(3, geometry.size.width * share))
                }
            }
            .frame(height: 6)

            Text(comparison(row))
                .font(.callout).foregroundStyle(.secondary)
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
        Text("These shares compare apps with each other. They do not add up to your whole battery — the screen, Wi-Fi and macOS itself also use power, and Runwell cannot measure every process.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}
