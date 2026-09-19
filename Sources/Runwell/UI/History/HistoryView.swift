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
    @State private var days: [HistoryStore.BatteryDay] = []
    @State private var episodes: [HistoryStore.InsightEpisode] = []
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
                SectionHeading("History")
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
                    episodesSection
                    sessionsSection
                    footnote
                }
            }
            .padding(Theme.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        days = (try? await store.batteryDays(from: from, to: to)) ?? []
        episodes = (try? await store.insightHistory(from: from, to: to)) ?? []
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
                    .font(Theme.Typography.title)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let drop, drop > 0 {
                Text("Your battery went down \(Int(drop))% in the last \(range.rawValue.lowercased()).")
                    .font(Theme.Typography.title)
            } else {
                Text("Nothing has used a noticeable amount of energy in the last \(range.rawValue.lowercased()).")
                    .font(Theme.Typography.title)
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
                Text("Battery level").font(Theme.Typography.title)
                Spacer()
                if let drop = batteryDrop, drop > 0 {
                    Text("Down \(Int(drop))%")
                        .font(Theme.Typography.callout).foregroundStyle(.secondary).monospacedDigit()
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

    // MARK: - Insight episodes

    /// Section 5.9 / 7.1. Conditions that held for a while, longest first.
    ///
    /// This is where an insight becomes useful rather than merely true. The
    /// sleep-prevention rule fires while the display is dark and withdraws the
    /// moment you wake the Mac, so the live list can never show you the episode you
    /// actually care about — you were not looking when it happened. Duration is the
    /// point: an app that held the machine awake for three hours is a different
    /// story from one that did it for thirty seconds.
    @ViewBuilder
    private var episodesSection: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.row + 2) {
                Text("What kept your Mac busy").font(Theme.Typography.title)

                VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                    ForEach(episodes) { episode in
                        episodeRow(episode)
                    }
                }
            }
        }
    }

    private func episodeRow(_ episode: HistoryStore.InsightEpisode) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.card) {
            // Section 8.5: symbol and words, never colour alone.
            Image(systemName: episode.rule.symbolName)
                .foregroundStyle(episode.severity == .warning ? .orange : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.rule.message(for: episode.appName))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text(episodeTiming(episode))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            if episode.ended == nil {
                // A condition that has not lapsed is still happening now.
                Text("Now")
                    .font(Theme.Typography.caption)
                    .padding(.horizontal, Theme.Spacing.row)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    /// When it happened and for how long, in the order a person would say it.
    private func episodeTiming(_ episode: HistoryStore.InsightEpisode) -> String {
        let duration = durationText(episode.duration())
        let start = episode.started.formatted(date: .omitted, time: .shortened)
        guard let ended = episode.ended else {
            return "Started at \(start) — \(duration) so far"
        }
        let finish = ended.formatted(date: .omitted, time: .shortened)
        return "\(start) to \(finish) — \(duration)"
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row + 2) {
            Text("Time on battery").font(Theme.Typography.title)
            if days.isEmpty {
                Text("Your Mac has been plugged in for this whole period.")
                    .font(Theme.Typography.callout).foregroundStyle(.secondary)
            } else {
                // Grouped by day rather than listed as raw runs. With the lid closed
                // macOS dark-wakes every 15–20 minutes, and each wake is its own run
                // with a long gap either side, so the ungrouped list was dozens of
                // accurate but meaningless "On battery for 0m" rows.
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 12) {
                            Image(systemName: "battery.50")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dayTitle(day.date)).fontWeight(.medium)
                                Text(daySummary(day))
                                    .font(Theme.Typography.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if let rate = day.percentagePerHour {
                                Text("\(Int(rate.rounded()))%/h")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
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

    /// "Today", "Yesterday", or a weekday and date.
    private func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Reads as a sentence. Says how much battery the day cost and over how much
    /// *observed* time — Appendix F: the gaps between dark-wakes were never sampled,
    /// so a fragmented day says so rather than implying the whole span was measured.
    private func daySummary(_ day: HistoryStore.BatteryDay) -> String {
        let used = Int(day.percentageUsed.rounded())
        let observed = durationText(day.observedDuration)
        let runs = day.sessions.count
        guard used > 0 else {
            return runs == 1
                ? "On battery for \(observed), no measurable drop"
                : "On battery across \(runs) short periods, no measurable drop"
        }
        if day.isFragmented {
            // The span is real, the observed time is small, and conflating them
            // would overstate what was actually measured.
            return "Used \(used)% across \(runs) periods, \(observed) of it measured "
                 + "— the rest of the time your Mac was asleep"
        }
        return runs == 1
            ? "Used \(used)% over \(observed)"
            : "Used \(used)% over \(observed) across \(runs) periods"
    }

    // MARK: - Consumers

    @ViewBuilder
    private var consumersSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.card) {
            HStack(alignment: .firstTextBaseline) {
                // "What used the most energy" implied the whole machine. These rows
                // only ever covered measurable applications — Section 3.1 mandates
                // the narrower claim, and the wording now matches what is counted.
                Text("Which apps used the most energy").font(Theme.Typography.title)
                Spacer()
                if let breakdown, !breakdown.rows.isEmpty {
                    Text("\(breakdown.rows.count) apps")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                }
            }

            if let breakdown, !breakdown.rows.isEmpty, breakdown.totalEnergyNJ > 0 {
                VStack(alignment: .leading, spacing: Theme.Spacing.card) {
                    ForEach(breakdown.rows) { row in
                        consumerRow(row, share: breakdown.share(of: row))
                    }
                    if breakdown.isPartial { coverageDisclosure(breakdown) }
                }
                .cardSurface()
            } else {
                Text("Nothing measurable yet.")
                    .font(Theme.Typography.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Section 3.1 / Appendix F: says plainly that these shares are of what Runwell
    /// could measure, not of the machine's total draw.
    ///
    /// macOS reports per-process energy only for processes the user owns, so the
    /// kernel, the window server and the rest of the system daemons — which
    /// genuinely account for much of a laptop's power — are not in these numbers at
    /// all. Measured against real battery discharge, the visible apps came to about
    /// an eighth of what the machine actually used. Nothing here can recover the
    /// rest, so the honest move is to say so on the same card as the percentages,
    /// rather than let a reader take "Chrome 62%" as 62% of their battery.
    private func coverageDisclosure(_ breakdown: HistoryStore.EnergyBreakdown) -> some View {
        let percent = Int(((breakdown.coverage ?? 0) * 100).rounded())
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text("Shares are of the energy Runwell could measure — about \(percent)% of "
                 + "processes. macOS does not report energy for system processes like "
                 + "the kernel and window server, so real battery use is higher than "
                 + "these totals.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
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
                        .font(Theme.Typography.caption).foregroundStyle(.orange)
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
                .font(Theme.Typography.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayName), \(Int((share * 100).rounded())) percent of measured energy. \(comparison(row))")
    }

    /// Translates average power into something recognisable. Watts are the unit people
    /// already read off appliances, and the phrasing stays comparative rather than
    /// claiming a share of the battery pack, which Section 3.1 forbids.
    ///
    /// Section 3 / Appendix F: a row can now genuinely have no measurable energy for
    /// the whole window rather than a coalesced 0 — an unreadable process previously
    /// reported "barely any power — 0.00 W", which is a specific, wrong claim dressed
    /// up as a modest one. That case says plainly that nothing could be measured.
    private func comparison(_ row: HistoryStore.BucketRow) -> String {
        guard let watts = row.averageWatts else {
            return "Could not measure this app's energy in this window."
        }
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
            .font(Theme.Typography.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}
