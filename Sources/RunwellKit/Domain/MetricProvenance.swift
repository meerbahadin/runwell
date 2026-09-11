import Foundation

/// Section 3: the measurement truth model.
///
/// Every value the UI shows carries one of these. This is a product requirement,
/// not an implementation detail: Runwell must never present an estimate as a
/// hardware measurement.
public enum MetricProvenance: String, Codable, Sendable, CaseIterable {
    /// Read directly from a system counter or power-source interface.
    case measured
    /// Calculated from two or more measured samples.
    case derived
    /// Inferred using an explicit model or incomplete coverage.
    case estimated
    /// Collector is under validation or may vary by OS/hardware.
    case experimental
    /// The OS, permissions or device cannot supply a trustworthy value.
    case unavailable

    /// Short badge text for the UI. Section 8 requires provenance to be visible.
    public var badge: String {
        switch self {
        case .measured: "Measured"
        case .derived: "Derived"
        case .estimated: "Estimated"
        case .experimental: "Experimental"
        case .unavailable: "Unavailable"
        }
    }

    /// Plain-language explanation, surfaced on hover and to VoiceOver (Section 8.5).
    public var explanation: String {
        switch self {
        case .measured: "Read directly from a system counter."
        case .derived: "Calculated from two or more measured samples."
        case .estimated: "Inferred using a model; treat as approximate."
        case .experimental: "This collector is still being validated."
        case .unavailable: "The system cannot supply a trustworthy value."
        }
    }
}

/// Why a collector could not produce a value. Appendix F: never display a missing
/// counter as zero — zero means measured zero, unavailable means unknown.
public enum UnavailableReason: String, Codable, Sendable {
    case permissionDenied
    case notSupportedOnThisOS
    case notSupportedOnThisHardware
    case collectorDisabled
    case awaitingSecondSample
    case invalidInterval
    case processExited

    public var userFacing: String {
        switch self {
        case .permissionDenied: "This process belongs to another user or the system."
        case .notSupportedOnThisOS: "Not available on this version of macOS."
        case .notSupportedOnThisHardware: "Not available on this Mac."
        case .collectorDisabled: "Turned off in Settings."
        case .awaitingSecondSample: "Measuring — needs one more sample."
        case .invalidInterval: "Skipped an unreliable sample interval."
        case .processExited: "The process exited."
        }
    }
}

/// Appendix B. A value plus the story of where it came from.
///
/// `value` is optional and `provenance` is independent of it: a present value can
/// still be `.experimental`, and an absent one always carries a reason.
public struct IntervalMetric<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value?
    public let provenance: MetricProvenance
    public let confidence: Double
    public let reasonUnavailable: UnavailableReason?

    public init(
        value: Value?,
        provenance: MetricProvenance,
        confidence: Double,
        reasonUnavailable: UnavailableReason? = nil
    ) {
        self.value = value
        self.provenance = provenance
        self.confidence = confidence
        self.reasonUnavailable = reasonUnavailable
    }

    public static func measured(_ value: Value, confidence: Double = 1.0) -> Self {
        .init(value: value, provenance: .measured, confidence: confidence)
    }

    public static func derived(_ value: Value, confidence: Double = 0.9) -> Self {
        .init(value: value, provenance: .derived, confidence: confidence)
    }

    public static func experimental(_ value: Value, confidence: Double = 0.3) -> Self {
        .init(value: value, provenance: .experimental, confidence: confidence)
    }

    public static func unavailable(_ reason: UnavailableReason) -> Self {
        .init(value: nil, provenance: .unavailable, confidence: 0, reasonUnavailable: reason)
    }

    public var isAvailable: Bool { value != nil }

    public func map<T: Sendable>(_ transform: (Value) -> T) -> IntervalMetric<T> {
        .init(
            value: value.map(transform),
            provenance: provenance,
            confidence: confidence,
            reasonUnavailable: reasonUnavailable
        )
    }
}

extension IntervalMetric where Value: BinaryFloatingPoint {
    /// Section 3 / Appendix F: an em dash for unknown, never a fabricated zero.
    public func formatted(_ format: String = "%.1f", suffix: String = "") -> String {
        guard let value else { return "—" }
        return String(format: format, Double(value)) + suffix
    }
}
