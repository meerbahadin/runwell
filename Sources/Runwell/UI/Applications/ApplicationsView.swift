import SwiftUI
import RunwellKit

/// Section 8.1 / 8.2. The sortable grouped application list.
struct ApplicationsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var expanded: Set<ApplicationGroupID> = []

    var body: some View {
        @Bindable var environment = environment

        VStack(spacing: 0) {
            if environment.isWaitingForFirstInterval {
                ContentUnavailableView {
                    Label("Measuring", systemImage: "hourglass")
                } description: {
                    Text("Rates are calculated between two samples. The first values appear after the next collection cycle.")
                }
            } else {
                table
            }
        }
        .navigationTitle("Applications")
        .searchable(text: $environment.searchText, prompt: "Search applications")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort by", selection: $environment.sortOrder) {
                    ForEach(AppEnvironment.SortColumn.allCases) { column in
                        Text(column.rawValue).tag(column)
                    }
                }
                .pickerStyle(.segmented)
                .help("Sort the application list")
            }
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                ForEach(environment.groups) { group in
                    ApplicationRow(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        share: environment.snapshot?.coverage.measuredAppShare(of: group),
                        normalizeCPU: environment.normalizeCPU,
                        coreCount: environment.capabilities.logicalProcessorCount,
                        onToggle: { toggle(group) }
                    )
                    .equatable()
                    .background(environment.selectedGroupID == group.id ? Color.accentColor.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { environment.selectedGroupID = group.id }
                    Divider()
                }
            }
        }
        // Section 8.2: rows must not reorder while the pointer is over the table.
        .onContinuousHover { phase in
            switch phase {
            case .active: environment.isPointerOverTable = true
            case .ended: environment.isPointerOverTable = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Application")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Energy").frame(width: 90, alignment: .trailing)
            Text("CPU").frame(width: 70, alignment: .trailing)
            Text("Memory").frame(width: 90, alignment: .trailing)
            Text("Status").frame(width: 150, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func toggle(_ group: ApplicationGroup) {
        // Section 12.2: expanding must not change the group total — the total is
        // always derived from members, so this only affects disclosure.
        if expanded.contains(group.id) {
            expanded.remove(group.id)
        } else {
            expanded.insert(group.id)
        }
    }
}

/// Section 8.2. One application row, with an expandable process tree (Section 1.3:
/// apps before processes, but always reversible).
struct ApplicationRow: View, Equatable {
    let group: ApplicationGroup
    let isExpanded: Bool
    let share: IntervalMetric<Double>?
    /// Passed in rather than read from `@Environment`. Observing the whole
    /// AppEnvironment made every row a dependency of every property on it, so any
    /// change re-rendered all ~166 rows; the row only needs these two values to
    /// format CPU. With them as plain inputs the row is Equatable, and SwiftUI can
    /// skip rows whose data did not change between sampler cycles.
    let normalizeCPU: Bool
    let coreCount: Int
    let onToggle: () -> Void

    nonisolated static func == (lhs: ApplicationRow, rhs: ApplicationRow) -> Bool {
        lhs.group == rhs.group
            && lhs.isExpanded == rhs.isExpanded
            && lhs.share == rhs.share
            && lhs.normalizeCPU == rhs.normalizeCPU
            && lhs.coreCount == rhs.coreCount
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    if group.processCount > 1 {
                        Button(action: onToggle) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? "Collapse processes" : "Expand \(group.processCount) processes")
                    } else {
                        Spacer().frame(width: 12)
                    }

                    AppIcon(bundleURL: group.bundleURL, size: 18)

                    Text(group.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // The name is what the row is for: let the badge give up
                        // space first, rather than truncating "Google Chrome" to
                        // "Goo…hrome" so a count can sit beside it.
                        .layoutPriority(1)

                    if group.processCount > 1 {
                        // Spelling out "processes" wrapped the capsule onto two
                        // lines in a narrow column and squeezed the name beside it.
                        // The count alone, with an icon that says what is being
                        // counted, fits and still reads.
                        Label("\(group.processCount)", systemImage: "square.stack.3d.up")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                            // `.help` on the Text alone tracks only the glyph
                            // bounds, so the capsule's padding was dead space and
                            // the tooltip mostly refused to appear. contentShape
                            // makes the whole capsule the hover target.
                            .contentShape(Capsule())
                            // The row above installs its own contentShape for the
                            // selection tap, which sits over the badge in hit-test
                            // order and swallowed the hover the tooltip needs. An
                            // explicit hover region on the badge claims it back.
                            .onHover { _ in }
                            .help("This application is running \(group.processCount) processes. Expand the row to see them.")
                            .accessibilityLabel("\(group.processCount) processes")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MetricText(metric: group.totalEnergyWatts, format: "%.2f", suffix: " W")
                    .frame(width: 90, alignment: .trailing)
                MetricText(
                    metric: displayCPU(group.totalCPUPercent, normalize: normalizeCPU,
                                      coreCount: coreCount),
                    format: "%.1f", suffix: "%"
                )
                    .frame(width: 70, alignment: .trailing)
                MemoryText(metric: group.totalFootprintBytes)
                    .frame(width: 90, alignment: .trailing)

                HStack(spacing: 4) {
                    StatusBadge(status: group.status)
                    Spacer(minLength: 0)
                }
                .frame(width: 150, alignment: .leading)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)

            if isExpanded {
                ForEach(group.members, id: \.key) { member in
                    ProcessSubRow(metrics: member, normalizeCPU: normalizeCPU,
                                  coreCount: coreCount)
                }
            }
        }
    }

    /// Section 8.5: VoiceOver gets the full picture in one utterance, including
    /// provenance and any unavailable reason.
    private var accessibilityDescription: String {
        var parts = [group.displayName]
        if group.processCount > 1 { parts.append("\(group.processCount) processes") }
        parts.append("Energy \(group.totalEnergyWatts.formatted("%.2f", suffix: " watts")), \(group.totalEnergyWatts.provenance.badge)")
        // VoiceOver should say the same number that is on screen.
        let cpu = displayCPU(group.totalCPUPercent, normalize: normalizeCPU,
                             coreCount: coreCount)
        parts.append("CPU \(cpu.formatted("%.1f", suffix: " percent"))")
        if let bytes = group.totalFootprintBytes.value {
            parts.append("Memory \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))")
        }
        if let label = group.status.label { parts.append(label) }
        return parts.joined(separator: ", ")
    }
}

/// A child process inside an expanded application group.
struct ProcessSubRow: View {
    let metrics: ProcessIntervalMetrics
    let normalizeCPU: Bool
    let coreCount: Int

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Spacer().frame(width: 30)
                Text(metrics.identity.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Text("PID \(metrics.identity.key.pid)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MetricText(metric: metrics.energyWatts, format: "%.2f", suffix: " W")
                .frame(width: 90, alignment: .trailing)
            MetricText(
                metric: displayCPU(metrics.cpuPercent, normalize: normalizeCPU,
                                   coreCount: coreCount),
                format: "%.1f", suffix: "%"
            )
                .frame(width: 70, alignment: .trailing)
            MemoryText(metric: metrics.physicalFootprintBytes)
                .frame(width: 90, alignment: .trailing)

            // Section 6: grouping must be explainable — this says why the process
            // was placed in this application.
            Text(metrics.identity.groupingReason.explanation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
                .help(metrics.identity.groupingReason.explanation)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.25))
    }
}
