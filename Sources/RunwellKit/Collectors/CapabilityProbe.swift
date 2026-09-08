import Foundation
import Darwin

/// Section 4 / 10.2. A capability-driven architecture: restricted or unavailable
/// collectors fail independently and are reported with a visible reason rather
/// than taking the application down with them.
public enum Collector: String, Sendable, CaseIterable {
    case processEnumeration
    case processCPU
    case processMemory
    case processEnergy
    case processDisk
    case processWakeups
    case battery
    case memoryPressure
    case sleepAssertions
    case totalGPU
    case perProcessGPU

    public var displayName: String {
        switch self {
        case .processEnumeration: "Process list"
        case .processCPU: "CPU"
        case .processMemory: "Memory"
        case .processEnergy: "Energy"
        case .processDisk: "Disk"
        case .processWakeups: "Wakeups"
        case .battery: "Battery"
        case .memoryPressure: "Memory pressure"
        case .sleepAssertions: "Sleep prevention"
        case .totalGPU: "Total GPU"
        case .perProcessGPU: "Per-process GPU"
        }
    }
}

public struct CapabilityStatus: Sendable {
    public let collector: Collector
    public let available: Bool
    public let reason: String
    /// Section 5.10: some collectors ship as experimental until validated.
    public let provenance: MetricProvenance
    public let osBuild: String
    public let hardwareModel: String

    public init(
        collector: Collector,
        available: Bool,
        reason: String,
        provenance: MetricProvenance,
        osBuild: String,
        hardwareModel: String
    ) {
        self.collector = collector
        self.available = available
        self.reason = reason
        self.provenance = provenance
        self.osBuild = osBuild
        self.hardwareModel = hardwareModel
    }
}

/// Section 12.3 go/no-go gates, evaluated at runtime on the machine actually running.
public struct CapabilitySet: Sendable {
    public let statuses: [Collector: CapabilityStatus]
    public let osBuild: String
    public let hardwareModel: String
    public let logicalProcessorCount: Int
    public let hasBattery: Bool

    public func isAvailable(_ collector: Collector) -> Bool {
        statuses[collector]?.available ?? false
    }

    public func status(_ collector: Collector) -> CapabilityStatus? { statuses[collector] }

    /// Section 12.3 energy gate: whether this Mac's energy counters read nonzero,
    /// monotonic and attributable — `.processEnergy`'s own availability, exposed
    /// under the name the gate is known by. No caller currently branches on this;
    /// it previously claimed a "ships an Energy Score only" fallback existed for a
    /// failing gate, but nothing in the app implements one — the honest behaviour
    /// today is that `.processEnergy` reports unavailable and energy values read
    /// as an em dash, the same as any other ungated unavailable metric.
    public var energyGatePassed: Bool { isAvailable(.processEnergy) }
}

/// Probes what this specific Mac and OS build can actually supply.
///
/// Appendix F: confirm field availability against the running system rather than
/// trusting documentation, and record the OS build locally — never in telemetry.
public struct CapabilityProbe: Sendable {
    public init() {}

    public func probe() -> CapabilitySet {
        let osBuild = Self.sysctlString("kern.osversion") ?? "unknown"
        let model = Self.sysctlString("hw.model") ?? "unknown"
        let cores = Int(ProcessInfo.processInfo.activeProcessorCount)

        var statuses: [Collector: CapabilityStatus] = [:]
        func record(_ c: Collector, _ available: Bool, _ reason: String, _ p: MetricProvenance) {
            statuses[c] = CapabilityStatus(
                collector: c, available: available, reason: reason,
                provenance: p, osBuild: osBuild, hardwareModel: model
            )
        }

        // Enumeration: can we list PIDs at all?
        let pidCount = proc_listallpids(nil, 0)
        record(.processEnumeration, pidCount > 0,
               pidCount > 0 ? "Listing \(pidCount) processes." : "The system refused to list processes.",
               .measured)

        // rusage-backed collectors. Probing our own process is the honest floor:
        // if it fails for us it will fail for everything.
        let selfProbe = Self.probeRusage(getpid())
        record(.processCPU, selfProbe != nil, selfProbe != nil ? "Reading CPU time counters." : "Resource counters unavailable.", .derived)
        record(.processMemory, selfProbe != nil, selfProbe != nil ? "Reading physical footprint." : "Resource counters unavailable.", .measured)
        record(.processDisk, selfProbe != nil, selfProbe != nil ? "Reading per-process disk counters." : "Resource counters unavailable.", .derived)
        record(.processWakeups, selfProbe != nil, selfProbe != nil ? "Reading wakeup counters." : "Resource counters unavailable.", .derived)

        // Section 12.3 energy gate. Appendix D Q1: does ri_energy_nj return useful
        // nonzero values? A structure that reads but reports a flat zero across the
        // machine has not passed the gate, so sample broadly rather than trusting
        // the field's mere presence.
        let energyOK = Self.probeEnergyCounters()
        record(.processEnergy, energyOK.passed, energyOK.reason, .measured)

        let battery = BatteryCollector().hasBattery()
        record(.battery, battery,
               battery ? "Power source reporting available." : "No battery in this Mac; running in resource-monitor mode.",
               .measured)

        // Section 8.3: the memory insight is gated on the kernel's own pressure
        // level. Without it the rule cannot be evidenced honestly, so it stays off
        // rather than falling back to a proxy that is always true.
        let pressure = MemoryPressureCollector().isAvailable()
        record(.memoryPressure, pressure,
               pressure ? "Reading the kernel memory pressure level."
                        : "kern.memorystatus_vm_pressure_level is unreadable on this system.",
               .measured)

        // Section 5.9: sleep assertions, via the documented IOKit interface rather
        // than the text output of pmset.
        let assertions = SleepAssertionCollector().isAvailable()
        record(.sleepAssertions, assertions,
               assertions ? "Reading power assertions by process."
                          : "The power-assertion interface did not answer.",
               .measured)

        // Section 5.7 GPU feasibility gate. Per-process GPU stays off until a
        // distributable interface with documented semantics is proven (Q3). The spec
        // is explicit that the UI must not infer it from total GPU utilization.
        record(.totalGPU, false, "Pending validation against a public IOKit accelerator contract.", .experimental)
        record(.perProcessGPU, false, "Blocked by the Section 12.3 GPU gate: no stable public per-process interface.", .experimental)

        return CapabilitySet(
            statuses: statuses,
            osBuild: osBuild,
            hardwareModel: model,
            logicalProcessorCount: cores,
            hasBattery: battery
        )
    }

    /// Reads rusage_info_v6 for a PID. Returns nil when the caller lacks permission
    /// or the structure is unsupported.
    static func probeRusage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    /// Appendix D Q1 / Section 12.3. Samples a spread of live processes and requires
    /// a real nonzero reading before declaring the energy collector available.
    private static func probeEnergyCounters() -> (passed: Bool, reason: String) {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return (false, "Could not enumerate processes to validate energy counters.") }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard count > 0 else { return (false, "Could not enumerate processes to validate energy counters.") }

        var readable = 0
        var nonzero = 0
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let info = probeRusage(pid) else { continue }
            readable += 1
            if info.ri_energy_nj > 0 { nonzero += 1 }
        }
        guard readable > 0 else {
            return (false, "No process resource counters are readable on this system.")
        }
        guard nonzero > 0 else {
            // The field exists but reports nothing on this hardware. Section 3:
            // that is unavailable, not a low reading — energy values fall back to
            // an em dash rather than a fabricated number.
            return (false, "Energy counters read as zero on this hardware; energy values will show as unavailable.")
        }
        return (true, "Validated on \(nonzero) of \(readable) readable processes.")
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctlbyname null-terminates the returned string; truncate at that point
        // before decoding rather than relying on the deprecated String(cString:),
        // which assumes but does not verify the same thing.
        let nulTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<nulTerminatorIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
