import Foundation

/// Section 6. An application-level row: the signature feature. A correct total for
/// Chrome or Xcode is more useful than a flat list of renderers and helpers.
public struct ApplicationGroup: Sendable, Identifiable {
    public let id: ApplicationGroupID
    public let displayName: String
    public let bundleURL: URL?
    public let members: [ProcessIntervalMetrics]

    /// Section 8.2: a short state string such as "Background activity".
    public let status: ApplicationStatus

    public init(
        id: ApplicationGroupID,
        displayName: String,
        bundleURL: URL?,
        members: [ProcessIntervalMetrics],
        status: ApplicationStatus
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.members = members
        self.status = status
    }

    public var processCount: Int { members.count }

    /// Section 12.2: group totals must be preserved when children expand or collapse.
    /// The total is always computed from members, never cached separately, so the two
    /// cannot drift apart.
    public var totalCPUPercent: IntervalMetric<Double> {
        Self.sum(members.map(\.cpuPercent))
    }

    public var totalFootprintBytes: IntervalMetric<UInt64> {
        Self.sum(members.map(\.physicalFootprintBytes))
    }

    public var totalEnergyWatts: IntervalMetric<Double> {
        Self.sum(members.map(\.energyWatts))
    }

    public var totalDiskBytesPerSecond: IntervalMetric<Double> {
        Self.sum(members.map { m in
            IntervalMetric<Double>(
                value: zip3(m.diskReadBytesPerSecond.value, m.diskWriteBytesPerSecond.value).map(+),
                provenance: m.diskReadBytesPerSecond.provenance,
                confidence: m.diskReadBytesPerSecond.confidence,
                reasonUnavailable: m.diskReadBytesPerSecond.reasonUnavailable
            )
        })
    }

    public var totalEnergyDeltaNJ: UInt64 {
        members.reduce(UInt64(0)) { $0 &+ ($1.energyDeltaNJ ?? 0) }
    }

    /// Summing partially-available values needs an explicit rule. If nothing in the
    /// group could be read the sum is unavailable — not zero (Appendix F). If only
    /// some members were readable the sum is real but under-counted, so confidence
    /// drops to the readable fraction and provenance degrades to `.estimated`.
    private static func sum<V: Numeric & Sendable>(_ metrics: [IntervalMetric<V>]) -> IntervalMetric<V> {
        guard !metrics.isEmpty else { return .unavailable(.processExited) }
        let available = metrics.filter(\.isAvailable)
        guard !available.isEmpty else {
            return .init(
                value: nil,
                provenance: .unavailable,
                confidence: 0,
                reasonUnavailable: metrics.first?.reasonUnavailable ?? .permissionDenied
            )
        }
        let total = available.reduce(V.zero) { $0 + ($1.value ?? .zero) }
        let coverage = Double(available.count) / Double(metrics.count)
        let worst = available.map(\.provenance).contains(.experimental) ? MetricProvenance.experimental
            : (coverage < 1 ? .estimated : available[0].provenance)
        let confidence = (available.map(\.confidence).min() ?? 0) * coverage
        return .init(value: total, provenance: worst, confidence: confidence)
    }
}

private func zip3<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Section 8.2 / 8.3. A short, honest state label for the row.
public enum ApplicationStatus: String, Sendable {
    case normal
    case highEnergy
    case backgroundActivity
    case highMemory

    public var label: String? {
        switch self {
        case .normal: nil
        case .highEnergy: "High energy"
        case .backgroundActivity: "Background activity"
        case .highMemory: "High memory"
        }
    }

    /// Section 8.5: severity is never encoded by color alone.
    public var symbolName: String? {
        switch self {
        case .normal: nil
        case .highEnergy: "bolt.fill"
        case .backgroundActivity: "moon.fill"
        case .highMemory: "memorychip.fill"
        }
    }
}

/// Section 3.1. The energy picture for one interval across the whole system.
///
/// The display, radios, DRAM and kernel work are not attributable to any user-facing
/// app, so application energy will not cover total discharge. This type keeps the
/// uncovered part explicit — Appendix F forbids normalizing app totals to 100%.
public struct EnergyCoverage: Sendable {
    public let groups: [ApplicationGroup]
    /// Total energy across every process PowerTask could actually read.
    public let accessibleEnergyNJ: UInt64
    /// Number of processes that existed but could not be read (Section 5.2).
    public let inaccessibleProcessCount: Int

    public init(groups: [ApplicationGroup], accessibleEnergyNJ: UInt64, inaccessibleProcessCount: Int) {
        self.groups = groups
        self.accessibleEnergyNJ = accessibleEnergyNJ
        self.inaccessibleProcessCount = inaccessibleProcessCount
    }

    /// Section 3.2: `measuredAppShare = appDeltaEnergyNJ / sum(allAccessibleProcessDeltaEnergyNJ)`.
    ///
    /// Section 3.1 requires this to be called "measured application energy share",
    /// never "battery percentage used" — it is a share of what PowerTask can see,
    /// not of the battery pack.
    public func measuredAppShare(of group: ApplicationGroup) -> IntervalMetric<Double> {
        guard accessibleEnergyNJ > 0 else { return .unavailable(.awaitingSecondSample) }
        let share = Double(group.totalEnergyDeltaNJ) / Double(accessibleEnergyNJ)
        // Confidence reflects how much of the machine we could see at all.
        let confidence = inaccessibleProcessCount == 0 ? 1.0
            : Double(groups.reduce(0) { $0 + $1.processCount })
                / Double(groups.reduce(0) { $0 + $1.processCount } + inaccessibleProcessCount)
        return .init(value: share, provenance: .derived, confidence: confidence)
    }

    /// The wording Section 3.1 mandates for this ratio.
    public static let shareLabel = "Measured application energy share"
}
