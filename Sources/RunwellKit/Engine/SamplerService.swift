import Foundation

/// Section 5.1. Sampling cadence. Lower frequency means less observer effect, which
/// Section 1.3 makes a product principle: the monitor must not itself drain the battery.
public enum SamplingMode: String, Sendable, CaseIterable {
    case foreground
    case menuBarOnly
    case batteryIdle
    case lowPowerMode
    case diagnosticBurst
    /// The user turned background recording off and the window is closed. Unlike
    /// every other mode, this one produces no samples at all: it exists so "stops
    /// recording" is an actual code path rather than just the slowest cadence.
    case paused

    /// Meaningless for `.paused` — the run loop checks `isPaused` before ever
    /// reading this, so it never sleeps for this duration on this mode's account.
    public var interval: Duration {
        switch self {
        case .foreground: .seconds(2)
        case .menuBarOnly: .seconds(5)
        case .batteryIdle: .seconds(10)
        case .lowPowerMode: .seconds(15)
        case .diagnosticBurst: .seconds(1)
        case .paused: .seconds(30)
        }
    }

    public var intervalSeconds: Double {
        switch self {
        case .foreground: 2
        case .menuBarOnly: 5
        case .batteryIdle: 10
        case .lowPowerMode: 15
        case .diagnosticBurst: 1
        case .paused: 30
        }
    }

    public var isPaused: Bool { self == .paused }

    public var description: String {
        switch self {
        case .foreground: "Every 2 seconds"
        case .menuBarOnly: "Every 5 seconds (menu bar only)"
        case .batteryIdle: "Every 10 seconds (on battery)"
        case .lowPowerMode: "Every 15 seconds (Low Power Mode)"
        case .diagnosticBurst: "Every second (diagnostic burst)"
        case .paused: "Not recording"
        }
    }
}

/// One cycle's published result. Section 4.2: the UI receives immutable view models.
public struct SamplerSnapshot: Sendable {
    public let sessionID: SampleSessionID
    public let groups: [ApplicationGroup]
    public let coverage: EnergyCoverage
    public let battery: BatterySnapshot
    public let capabilities: CapabilitySet
    public let mode: SamplingMode
    public let cycleDuration: Duration
    public let skippedCycles: Int
    public let isFirstSample: Bool
    /// Section 5.9: processes preventing sleep, and whether the display is dark.
    /// Nil when the interface could not be read — unknown, not "none".
    public let sleepAssertions: [SleepAssertionCollector.Assertion]?
    public let displayIsAsleep: Bool

    public init(
        sessionID: SampleSessionID,
        groups: [ApplicationGroup],
        coverage: EnergyCoverage,
        battery: BatterySnapshot,
        capabilities: CapabilitySet,
        mode: SamplingMode,
        cycleDuration: Duration,
        skippedCycles: Int,
        isFirstSample: Bool,
        sleepAssertions: [SleepAssertionCollector.Assertion]? = nil,
        displayIsAsleep: Bool = false
    ) {
        self.sessionID = sessionID
        self.groups = groups
        self.coverage = coverage
        self.battery = battery
        self.capabilities = capabilities
        self.mode = mode
        self.cycleDuration = cycleDuration
        self.skippedCycles = skippedCycles
        self.isFirstSample = isFirstSample
        self.sleepAssertions = sleepAssertions
        self.displayIsAsleep = displayIsAsleep
    }
}

/// Section 4.1 / Appendix C. Owns the timer, collector scheduling and backpressure.
///
/// An actor because the sample cache is mutable state touched from a background
/// cadence while the UI reads published snapshots.
public actor SamplerService {
    private let processCollector = ProcessCollector()
    private let batteryCollector = BatteryCollector()
    private let grouper = ApplicationGrouper()
    private var metricEngine: MetricEngine
    private let capabilities: CapabilitySet

    /// Appendix C's `cache`: the previous snapshot per process, keyed by identity.
    private var previousSnapshots: [ProcessKey: RawProcessSnapshot] = [:]
    private var sessionID = SampleSessionID()
    private var mode: SamplingMode = .foreground

    /// Section 10.2: never start a cycle while the previous one is still running;
    /// record a skipped-cycle counter.
    private var isCollecting = false
    private(set) public var skippedCycles = 0
    private var overBudgetCycles = 0
    private var hasEmittedFirstSample = false

    private var continuation: AsyncStream<SamplerSnapshot>.Continuation?
    public nonisolated let snapshots: AsyncStream<SamplerSnapshot>

    private let sleepAssertionCollector = SleepAssertionCollector()

    public init(capabilities: CapabilitySet) {
        self.capabilities = capabilities
        self.metricEngine = MetricEngine(
            configuration: .init(logicalProcessorCount: capabilities.logicalProcessorCount)
        )
        var escaped: AsyncStream<SamplerSnapshot>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { escaped = $0 }
        self.continuation = escaped
    }

    public func setMode(_ newMode: SamplingMode) {
        guard newMode != mode else { return }
        mode = newMode
    }

    public func currentMode() -> SamplingMode { mode }

    /// Section 7.3. A new session at every boundary — collector restart, wake from
    /// sleep, power-source transition — so deltas never bridge across one.
    public func beginNewSession() {
        sessionID = SampleSessionID()
        previousSnapshots.removeAll(keepingCapacity: true)
        hasEmittedFirstSample = false
    }

    public func run() async {
        while !Task.isCancelled {
            let interval = mode.interval
            // Paused means paused: no collector call, no snapshot, no write to
            // history. The loop still wakes on `interval` so a mode change (window
            // reopened, setting flipped) is noticed promptly rather than only on
            // the next natural tick.
            if !mode.isPaused {
                await tick()
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Appendix C's `onTick`.
    public func tick(workspace: ApplicationGrouper.WorkspaceSnapshot? = nil) async {
        guard !isCollecting else {
            skippedCycles += 1
            return
        }
        isCollecting = true
        defer { isCollecting = false }

        let started = MonotonicInstant.now()
        let resolvedWorkspace: ApplicationGrouper.WorkspaceSnapshot
        if let workspace {
            resolvedWorkspace = workspace
        } else {
            resolvedWorkspace = await MainActor.run { ApplicationGrouper.WorkspaceSnapshot.capture() }
        }

        let capture = processCollector.capture()
        let battery = batteryCollector.capture()
        // Section 5.9. Cheap to read, and only meaningful together with whether the
        // display is dark, so both are captured in the same cycle.
        let assertions = capabilities.isAvailable(.sleepAssertions)
            ? sleepAssertionCollector.capture() : nil
        let displayAsleep = sleepAssertionCollector.displayIsAsleep()

        var metrics: [ProcessIntervalMetrics] = []
        metrics.reserveCapacity(capture.snapshots.count)
        var accessibleEnergyNJ: UInt64 = 0

        for snapshot in capture.snapshots {
            guard let raw = capture.rawIdentities[snapshot.key] else { continue }
            let identity = grouper.resolve(
                raw: raw,
                key: snapshot.key,
                workspace: resolvedWorkspace,
                allRawIdentities: capture.rawIdentities
            )

            if let previous = previousSnapshots[snapshot.key],
               let interval = metricEngine.calculate(
                   previous: previous,
                   current: snapshot,
                   identity: identity
               ) {
                metrics.append(interval)
                accessibleEnergyNJ &+= interval.energyDeltaNJ ?? 0
            }
            // The baseline advances whether or not the interval was valid: a rejected
            // interval resets the delta rather than emitting a bad one (Section 3.2).
            previousSnapshots[snapshot.key] = snapshot
        }

        // Appendix C: remove exited processes from the cache.
        let living = Set(capture.snapshots.map(\.key))
        previousSnapshots = previousSnapshots.filter { living.contains($0.key) }
        grouper.pruneCache(livingKeys: living)

        let groups = grouper.group(metrics: metrics, workspace: resolvedWorkspace)
        let coverage = EnergyCoverage(
            groups: groups,
            accessibleEnergyNJ: accessibleEnergyNJ,
            inaccessibleProcessCount: capture.inaccessibleCount
        )

        let elapsedNS = MonotonicInstant.now().nanoseconds - started.nanoseconds
        let duration = Duration.nanoseconds(Int64(clamping: elapsedNS))
        applyBackpressure(cycleSeconds: Double(elapsedNS) / 1_000_000_000)

        let isFirst = !hasEmittedFirstSample
        if !metrics.isEmpty { hasEmittedFirstSample = true }

        continuation?.yield(SamplerSnapshot(
            sessionID: sessionID,
            groups: groups,
            coverage: coverage,
            battery: battery,
            capabilities: capabilities,
            mode: mode,
            cycleDuration: duration,
            skippedCycles: skippedCycles,
            isFirstSample: isFirst,
            sleepAssertions: assertions,
            displayIsAsleep: displayAsleep
        ))
    }

    /// Section 10.1: p95 collection cycle under 25% of the configured interval.
    /// Section 10.2: after three over-budget cycles, back the interval off.
    private func applyBackpressure(cycleSeconds: Double) {
        let budget = mode.intervalSeconds * 0.25
        if cycleSeconds > budget {
            overBudgetCycles += 1
            if overBudgetCycles >= 3 {
                overBudgetCycles = 0
                switch mode {
                case .foreground: mode = .menuBarOnly
                case .menuBarOnly: mode = .batteryIdle
                // Reached only from a completed tick, and .paused never ticks —
                // still handled so the switch stays exhaustive against the enum.
                case .batteryIdle, .lowPowerMode, .diagnosticBurst, .paused: break
                }
            }
        } else {
            overBudgetCycles = 0
        }
    }
}
