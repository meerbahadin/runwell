import Testing
import Foundation
@testable import RunwellKit

/// Section 11.1 unit layer: delta arithmetic, PID reuse, counter reset and smoothing.

private func snapshot(
    pid: pid_t = 100,
    start: UInt64 = 1_000,
    atSeconds: Double,
    cpuNS: UInt64? = 0,
    energyNJ: UInt64? = 0,
    footprint: UInt64? = 1_000_000,
    diskRead: UInt64? = 0,
    availability: CollectorAvailability = .ok
) -> RawProcessSnapshot {
    RawProcessSnapshot(
        key: ProcessKey(pid: pid, startAbsoluteTime: start),
        capturedAt: MonotonicInstant(nanoseconds: UInt64(atSeconds * 1_000_000_000)),
        userTimeNS: cpuNS,
        systemTimeNS: cpuNS.map { _ in 0 },
        physicalFootprintBytes: footprint,
        diskReadBytes: diskRead,
        diskWriteBytes: 0,
        energyNJ: energyNJ,
        idleWakeups: 0,
        interruptWakeups: 0,
        availability: availability
    )
}

private let testIdentity = ProcessIdentity(
    key: ProcessKey(pid: 100, startAbsoluteTime: 1_000),
    name: "TestApp",
    executable: ExecutableIdentity(executablePath: "/Applications/TestApp.app/Contents/MacOS/TestApp", signingIdentifier: nil),
    parentPID: 1,
    userID: 501,
    groupID: ApplicationGroupID(bundle: "com.example.TestApp"),
    groupDisplayName: "TestApp",
    groupingReason: .bundleOwnership,
    bundleURL: nil,
    isPrincipalProcess: true
)

@Suite("Delta arithmetic")
struct DeltaTests {
    let engine = MetricEngine(configuration: .init(logicalProcessorCount: 10))

    @Test("CPU percentage follows the Section 5.3 formula")
    func cpuFormula() throws {
        // One full second of CPU time across a two-second wall interval = 50%.
        let previous = snapshot(atSeconds: 0, cpuNS: 0)
        let current = snapshot(atSeconds: 2, cpuNS: 1_000_000_000)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        let cpu = try #require(metrics.cpuPercent.value)
        #expect(abs(cpu - 50.0) < 0.001)
        // Section 3: a rate computed across samples is derived, never measured.
        #expect(metrics.cpuPercent.provenance == .derived)
    }

    @Test("Raw CPU may exceed 100% for a multithreaded process")
    func multithreadedCPU() throws {
        // Four cores' worth of work in one second.
        let previous = snapshot(atSeconds: 0, cpuNS: 0)
        let current = snapshot(atSeconds: 1, cpuNS: 4_000_000_000)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        #expect(try #require(metrics.cpuPercent.value) > 100)
    }

    @Test("Normalized mode divides by core count")
    func normalizedCPU() throws {
        let normalizing = MetricEngine(configuration: .init(
            normalizeCPUToCoreCount: true,
            logicalProcessorCount: 10
        ))
        let previous = snapshot(atSeconds: 0, cpuNS: 0)
        let current = snapshot(atSeconds: 1, cpuNS: 4_000_000_000)
        let metrics = try #require(normalizing.calculate(previous: previous, current: current, identity: testIdentity))
        // 400% raw across 10 cores = 40% normalized.
        #expect(abs(try #require(metrics.cpuPercent.value) - 40.0) < 0.001)
    }

    @Test("Energy watts follow the Section 3.2 formula")
    func energyFormula() throws {
        // 2 joules over 2 seconds = 1 watt.
        let previous = snapshot(atSeconds: 0, energyNJ: 0)
        let current = snapshot(atSeconds: 2, energyNJ: 2_000_000_000)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        #expect(abs(try #require(metrics.energyWatts.value) - 1.0) < 0.0001)
        #expect(metrics.energyDeltaNJ == 2_000_000_000)
    }

    @Test("Disk throughput is a per-second rate")
    func diskRate() throws {
        let previous = snapshot(atSeconds: 0, diskRead: 0)
        let current = snapshot(atSeconds: 4, diskRead: 4_096)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        #expect(abs(try #require(metrics.diskReadBytesPerSecond.value) - 1_024) < 0.001)
    }
}

@Suite("Invalid interval rejection")
struct RejectionTests {
    let engine = MetricEngine(configuration: .init(logicalProcessorCount: 10))

    @Test("PID reuse is rejected rather than producing a false delta")
    func pidReuse() {
        // Same PID, different start time: a new program wearing a recycled PID.
        let previous = snapshot(pid: 100, start: 1_000, atSeconds: 0, cpuNS: 5_000_000_000)
        let current = snapshot(pid: 100, start: 9_999, atSeconds: 2, cpuNS: 0)
        #expect(engine.calculate(previous: previous, current: current, identity: testIdentity) == nil)
        #expect(engine.validateInterval(previous: previous, current: current) == .failure(.identityChanged))
    }

    @Test("A counter reset is rejected, not clamped to zero")
    func counterReset() throws {
        // Section 3.2: these counters are monotonic, so a decrease is a reset.
        let previous = snapshot(atSeconds: 0, cpuNS: 5_000_000_000, energyNJ: 5_000_000_000)
        let current = snapshot(atSeconds: 2, cpuNS: 1_000_000_000, energyNJ: 1_000_000_000)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        // The interval itself is valid, but the reset counters cannot yield a rate.
        #expect(!metrics.cpuPercent.isAvailable)
        #expect(!metrics.energyWatts.isAvailable)
        #expect(metrics.cpuPercent.provenance == .unavailable)
        #expect(metrics.energyDeltaNJ == nil)
    }

    @Test("An excessive interval is rejected (sleep, stall)")
    func excessiveInterval() {
        let previous = snapshot(atSeconds: 0)
        let current = snapshot(atSeconds: 3_600)
        #expect(engine.validateInterval(previous: previous, current: current) == .failure(.intervalTooLong(3_600)))
        #expect(engine.calculate(previous: previous, current: current, identity: testIdentity) == nil)
    }

    @Test("A too-short interval is rejected as timer jitter")
    func tooShort() {
        let previous = snapshot(atSeconds: 0)
        let current = snapshot(atSeconds: 0.01)
        #expect(engine.calculate(previous: previous, current: current, identity: testIdentity) == nil)
    }

    @Test("A backwards clock is rejected")
    func nonMonotonic() {
        let previous = snapshot(atSeconds: 10)
        let current = snapshot(atSeconds: 5)
        #expect(engine.validateInterval(previous: previous, current: current) == .failure(.nonMonotonicClock))
    }

    @Test("An implausible CPU jump is rejected, not displayed")
    func implausibleCPU() throws {
        // 100 cores' worth of work claimed on a 10-core machine.
        let previous = snapshot(atSeconds: 0, cpuNS: 0)
        let current = snapshot(atSeconds: 1, cpuNS: 100_000_000_000)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        #expect(!metrics.cpuPercent.isAvailable)
        #expect(metrics.cpuPercent.reasonUnavailable == .invalidInterval)
    }

    @Test("A denied process yields unavailable metrics, never zeros")
    func deniedProcess() throws {
        // Appendix F: zero means measured zero; unavailable means unknown.
        let previous = snapshot(atSeconds: 0, availability: .denied(.permissionDenied))
        let current = snapshot(atSeconds: 2, cpuNS: nil, energyNJ: nil, footprint: nil,
                               availability: .denied(.permissionDenied))
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        #expect(!metrics.cpuPercent.isAvailable)
        #expect(!metrics.energyWatts.isAvailable)
        #expect(!metrics.physicalFootprintBytes.isAvailable)
        #expect(metrics.cpuPercent.reasonUnavailable == .permissionDenied)
    }

    @Test("Missing counters read as unavailable rather than zero")
    func missingCounters() throws {
        let previous = snapshot(atSeconds: 0, energyNJ: nil)
        let current = snapshot(atSeconds: 2, energyNJ: nil)
        let metrics = try #require(engine.calculate(previous: previous, current: current, identity: testIdentity))
        #expect(!metrics.energyWatts.isAvailable)
        #expect(metrics.energyWatts.formatted() == "—")
    }
}
