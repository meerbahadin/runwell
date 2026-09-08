import Foundation
import Darwin

/// Section 8.3. The system-wide memory pressure level, read from the kernel.
///
/// Appendix F: this is deliberately *not* derived from summing per-process
/// footprints. Footprints double-count shared pages and their total crosses any
/// fixed byte threshold on an idle modern Mac, so a sum can only ever answer
/// "yes" — it cannot distinguish a system under pressure from one merely running
/// applications. The kernel already computes the verdict; Runwell reads it.
public enum MemoryPressureLevel: String, Sendable, Codable {
    case normal
    case warning
    case critical

    /// Only warning and critical are pressure. Section 8.3's memory rule is gated on
    /// this, so that a healthy system raises nothing at all.
    public var isUnderPressure: Bool { self != .normal }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

/// Reads `kern.memorystatus_vm_pressure_level`, the same signal that backs
/// `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`. The values are the documented dispatch
/// constants: NORMAL 1, WARN 2, CRITICAL 4.
public struct MemoryPressureCollector: Sendable {
    public init() {}

    /// Returns the level, or `.unavailable` when the sysctl cannot be read. Per
    /// Section 3, an unreadable source is unknown — never reported as "normal",
    /// which would be a measurement we did not take.
    public func read() -> IntervalMetric<MemoryPressureLevel> {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unavailable(.notSupportedOnThisOS)
        }
        switch level {
        case 1: return .measured(.normal)
        case 2: return .measured(.warning)
        case 4: return .measured(.critical)
        default:
            // An undocumented level is not something to guess a meaning for.
            return .unavailable(.notSupportedOnThisOS)
        }
    }

    /// Capability probe support: the sysctl must both exist and report a level we
    /// recognise before the memory rule is allowed to run.
    public func isAvailable() -> Bool { read().isAvailable }
}
