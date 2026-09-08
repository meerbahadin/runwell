import Foundation

/// Section 5.3 / 3.2. Turns pairs of raw snapshots into interval metrics.
///
/// Section 3.2: samples with a changed process start time, a negative delta, an
/// implausible jump or an excessive interval are *reset rather than emitted*. This
/// engine is where that rule is enforced, so a bad sample can never reach the UI.
public struct MetricEngine: Sendable {
    public struct Configuration: Sendable {
        /// An interval far longer than the sampling period means something stalled —
        /// sleep, a wedged cycle, a suspended app. Deltas across it are not meaningful.
        public var maximumIntervalSeconds: Double
        /// Below this, timer jitter dominates and rates become noise.
        public var minimumIntervalSeconds: Double
        /// Section 5.3: raw macOS-style CPU percentage may exceed 100% for a
        /// multithreaded process. A value beyond every core running flat out is a
        /// counter artifact, not a busy process.
        public var implausibleCPUPercentMultiplier: Double
        /// Section 5.3: default to raw macOS-style percentage; a setting switches
        /// to a normalized 0-100% display.
        public var normalizeCPUToCoreCount: Bool
        public var logicalProcessorCount: Int

        public init(
            maximumIntervalSeconds: Double = 60,
            minimumIntervalSeconds: Double = 0.2,
            implausibleCPUPercentMultiplier: Double = 1.5,
            normalizeCPUToCoreCount: Bool = false,
            logicalProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
        ) {
            self.maximumIntervalSeconds = maximumIntervalSeconds
            self.minimumIntervalSeconds = minimumIntervalSeconds
            self.implausibleCPUPercentMultiplier = implausibleCPUPercentMultiplier
            self.normalizeCPUToCoreCount = normalizeCPUToCoreCount
            self.logicalProcessorCount = logicalProcessorCount
        }
    }

    public var configuration: Configuration
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Why a pair of snapshots did not produce metrics.
    public enum IntervalRejection: Error, Sendable, Equatable {
        case identityChanged
        case intervalTooLong(Double)
        case intervalTooShort(Double)
        case nonMonotonicClock
    }

    /// Section 3.2 and Appendix C's `intervalIsValid`.
    public func validateInterval(
        previous: RawProcessSnapshot,
        current: RawProcessSnapshot
    ) -> Result<Double, IntervalRejection> {
        // PID + start time. A mismatch means PID reuse handed us a different program;
        // bridging counters across that would invent load out of nothing.
        guard previous.key == current.key else { return .failure(.identityChanged) }
        guard let seconds = current.capturedAt.secondsSince(previous.capturedAt) else {
            return .failure(.nonMonotonicClock)
        }
        guard seconds <= configuration.maximumIntervalSeconds else {
            return .failure(.intervalTooLong(seconds))
        }
        guard seconds >= configuration.minimumIntervalSeconds else {
            return .failure(.intervalTooShort(seconds))
        }
        return .success(seconds)
    }

    /// Computes one interval's metrics. Returns nil when the interval is invalid —
    /// the caller replaces its cached baseline and emits nothing for this cycle.
    public func calculate(
        previous: RawProcessSnapshot,
        current: RawProcessSnapshot,
        identity: ProcessIdentity
    ) -> ProcessIntervalMetrics? {
        guard case .success(let seconds) = validateInterval(previous: previous, current: current) else {
            return nil
        }

        if case .denied(let reason) = current.availability {
            return ProcessIntervalMetrics(
                key: current.key,
                identity: identity,
                intervalSeconds: seconds,
                cpuPercent: .unavailable(reason),
                physicalFootprintBytes: .unavailable(reason),
                energyWatts: .unavailable(reason),
                energyDeltaNJ: nil,
                diskReadBytesPerSecond: .unavailable(reason),
                diskWriteBytesPerSecond: .unavailable(reason),
                wakeupsPerSecond: .unavailable(reason)
            )
        }

        // Section 5.3:
        //   rawCPUPercent = 100 * delta(userTimeNS + systemTimeNS) / deltaWallTimeNS
        let cpuPercent: IntervalMetric<Double>
        if let deltaCPU = Self.counterDelta(previous.totalCPUTimeNS, current.totalCPUTimeNS) {
            var percent = 100 * Double(deltaCPU) / (seconds * 1_000_000_000)
            let ceiling = 100 * Double(configuration.logicalProcessorCount)
                * configuration.implausibleCPUPercentMultiplier
            if percent > ceiling {
                cpuPercent = .unavailable(.invalidInterval)
            } else {
                if configuration.normalizeCPUToCoreCount {
                    percent /= Double(configuration.logicalProcessorCount)
                }
                cpuPercent = .derived(percent)
            }
        } else {
            cpuPercent = .unavailable(.permissionDenied)
        }

        // Section 5.4: physical footprint is a gauge, not a counter — the current
        // reading is the measured value, with no delta involved.
        let footprint: IntervalMetric<UInt64> = current.physicalFootprintBytes
            .map { .measured($0) } ?? .unavailable(.permissionDenied)

        // Section 3.2:
        //   deltaEnergyNJ = max(0, current.energyNJ - previous.energyNJ)
        //   processWatts  = deltaEnergyNJ / deltaSeconds / 1_000_000_000
        var energyDeltaNJ: UInt64?
        let energyWatts: IntervalMetric<Double>
        if let delta = Self.counterDelta(previous.energyNJ, current.energyNJ) {
            energyDeltaNJ = delta
            let watts = Double(delta) / seconds / 1_000_000_000
            // Section 5.5: the counter is measured, the watt figure is derived from
            // two of those measurements.
            energyWatts = .derived(watts, confidence: 0.85)
        } else {
            energyWatts = .unavailable(
                current.energyNJ == nil ? .permissionDenied : .invalidInterval
            )
        }

        let readRate = Self.rate(previous.diskReadBytes, current.diskReadBytes, seconds)
        let writeRate = Self.rate(previous.diskWriteBytes, current.diskWriteBytes, seconds)

        // Section 5.8: package idle and interrupt wakeups support energy explanations.
        let wakeups: IntervalMetric<Double>
        let idle = Self.counterDelta(previous.idleWakeups, current.idleWakeups)
        let interrupt = Self.counterDelta(previous.interruptWakeups, current.interruptWakeups)
        if idle != nil || interrupt != nil {
            wakeups = .derived(Double((idle ?? 0) + (interrupt ?? 0)) / seconds)
        } else {
            wakeups = .unavailable(.permissionDenied)
        }

        return ProcessIntervalMetrics(
            key: current.key,
            identity: identity,
            intervalSeconds: seconds,
            cpuPercent: cpuPercent,
            physicalFootprintBytes: footprint,
            energyWatts: energyWatts,
            energyDeltaNJ: energyDeltaNJ,
            diskReadBytesPerSecond: readRate,
            diskWriteBytesPerSecond: writeRate,
            wakeupsPerSecond: wakeups
        )
    }

    /// Section 3.2. These counters are monotonic by contract, so a decrease means the
    /// counter reset — not negative work. Returning nil rejects the interval instead
    /// of clamping a reset to zero, which would silently hide the discontinuity.
    static func counterDelta(_ previous: UInt64?, _ current: UInt64?) -> UInt64? {
        guard let previous, let current else { return nil }
        guard current >= previous else { return nil }
        return current - previous
    }

    static func rate(_ previous: UInt64?, _ current: UInt64?, _ seconds: Double) -> IntervalMetric<Double> {
        guard let delta = counterDelta(previous, current) else {
            return .unavailable(previous == nil || current == nil ? .permissionDenied : .invalidInterval)
        }
        return .derived(Double(delta) / seconds)
    }
}
