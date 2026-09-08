import Foundation

/// Appendix F: units live in field names and types — nanoseconds, nanojoules,
/// bytes and monotonic instants.

/// Section 5.2 / Appendix B. A raw counter reading. Collectors return these and
/// never calculate UI rates themselves (Section 4.2).
public struct RawProcessSnapshot: Sendable {
    public let key: ProcessKey
    public let capturedAt: MonotonicInstant
    public let userTimeNS: UInt64?
    public let systemTimeNS: UInt64?
    public let physicalFootprintBytes: UInt64?
    public let residentBytes: UInt64?
    public let diskReadBytes: UInt64?
    public let diskWriteBytes: UInt64?
    public let energyNJ: UInt64?
    public let idleWakeups: UInt64?
    public let interruptWakeups: UInt64?
    public let availability: CollectorAvailability

    public init(
        key: ProcessKey,
        capturedAt: MonotonicInstant,
        userTimeNS: UInt64? = nil,
        systemTimeNS: UInt64? = nil,
        physicalFootprintBytes: UInt64? = nil,
        residentBytes: UInt64? = nil,
        diskReadBytes: UInt64? = nil,
        diskWriteBytes: UInt64? = nil,
        energyNJ: UInt64? = nil,
        idleWakeups: UInt64? = nil,
        interruptWakeups: UInt64? = nil,
        availability: CollectorAvailability
    ) {
        self.key = key
        self.capturedAt = capturedAt
        self.userTimeNS = userTimeNS
        self.systemTimeNS = systemTimeNS
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNJ = energyNJ
        self.idleWakeups = idleWakeups
        self.interruptWakeups = interruptWakeups
        self.availability = availability
    }

    public var totalCPUTimeNS: UInt64? {
        guard let userTimeNS, let systemTimeNS else { return nil }
        return userTimeNS &+ systemTimeNS
    }
}

/// Whether a per-process read succeeded, and if not, why. Section 5.2 requires
/// permission failures to be represented per process rather than globally.
public enum CollectorAvailability: Sendable, Equatable {
    case ok
    case partial(UnavailableReason)
    case denied(UnavailableReason)

    public var isReadable: Bool {
        if case .denied = self { return false }
        return true
    }
}

/// Section 3.2. A monotonic timestamp. Wall-clock time can jump; this cannot,
/// which is what makes an interval trustworthy across sleep and clock changes.
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    public static func now() -> MonotonicInstant {
        .init(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Seconds elapsed since an earlier instant. Negative intervals are impossible
    /// by construction and are reported as nil rather than clamped.
    public func secondsSince(_ earlier: MonotonicInstant) -> Double? {
        guard nanoseconds >= earlier.nanoseconds else { return nil }
        return Double(nanoseconds - earlier.nanoseconds) / 1_000_000_000
    }
}

/// One process's metrics over one validated interval. Every field carries its own
/// provenance because collectors fail independently (Section 4).
public struct ProcessIntervalMetrics: Sendable {
    public let key: ProcessKey
    public let identity: ProcessIdentity
    public let intervalSeconds: Double
    public let cpuPercent: IntervalMetric<Double>
    public let physicalFootprintBytes: IntervalMetric<UInt64>
    public let energyWatts: IntervalMetric<Double>
    public let energyDeltaNJ: UInt64?
    public let diskReadBytesPerSecond: IntervalMetric<Double>
    public let diskWriteBytesPerSecond: IntervalMetric<Double>
    public let wakeupsPerSecond: IntervalMetric<Double>

    public init(
        key: ProcessKey,
        identity: ProcessIdentity,
        intervalSeconds: Double,
        cpuPercent: IntervalMetric<Double>,
        physicalFootprintBytes: IntervalMetric<UInt64>,
        energyWatts: IntervalMetric<Double>,
        energyDeltaNJ: UInt64?,
        diskReadBytesPerSecond: IntervalMetric<Double>,
        diskWriteBytesPerSecond: IntervalMetric<Double>,
        wakeupsPerSecond: IntervalMetric<Double>
    ) {
        self.key = key
        self.identity = identity
        self.intervalSeconds = intervalSeconds
        self.cpuPercent = cpuPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.energyWatts = energyWatts
        self.energyDeltaNJ = energyDeltaNJ
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.wakeupsPerSecond = wakeupsPerSecond
    }
}

/// Section 5.6. Battery and power-source state.
public struct BatterySnapshot: Sendable {
    public enum PowerSource: String, Sendable {
        case battery
        case wallPower
        case unknown
    }

    public let percentage: IntervalMetric<Double>
    public let powerSource: PowerSource
    public let isCharging: Bool
    /// Distinct from `isCharging`: a full battery sitting on AC is neither charging
    /// nor discharging, and has no meaningful time estimate.
    public let isCharged: Bool
    public let isPresent: Bool
    /// OS-provided estimate. Section 5.10 marks this measured-or-estimated *by the OS*:
    /// PowerTask passes it through rather than inventing its own model.
    public let timeRemaining: IntervalMetric<TimeInterval>
    public let capturedAt: MonotonicInstant

    public init(
        percentage: IntervalMetric<Double>,
        powerSource: PowerSource,
        isCharging: Bool,
        isCharged: Bool = false,
        isPresent: Bool,
        timeRemaining: IntervalMetric<TimeInterval>,
        capturedAt: MonotonicInstant
    ) {
        self.percentage = percentage
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.isPresent = isPresent
        self.timeRemaining = timeRemaining
        self.capturedAt = capturedAt
    }
}
