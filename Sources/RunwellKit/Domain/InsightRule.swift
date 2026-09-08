import Foundation

/// Section 8.3. The rules, their evidence and the exact wording shown to the user.
///
/// These are deterministic rules rather than a model: Appendix F's final rule is that
/// anything in the default UI must be explainable and unit-testable, and "why did it
/// say that?" must have an answer in code.
public enum InsightRule: String, Sendable, CaseIterable, Codable {
    case sustainedEnergy
    case hiddenBackgroundLoad
    case memoryPressure
    case wakeupStorm
    /// Section 5.9 / 8.3: kept out of the MVP until a supported assertion source can
    /// be mapped to an application without parsing privileged command output.
    case sleepPrevention

    /// How long the condition must hold before the insight is raised (Section 8.3).
    public var sustainedFor: TimeInterval {
        switch self {
        case .sustainedEnergy: 60
        case .hiddenBackgroundLoad: 120
        case .memoryPressure: 60
        case .wakeupStorm: 60
        case .sleepPrevention: 0
        }
    }

    /// Section 8.3's user wording, with the app name substituted.
    public func message(for app: String) -> String {
        switch self {
        case .sustainedEnergy:
            "\(app) has used high measured energy for the last minute."
        case .hiddenBackgroundLoad:
            "\(app) is consuming energy while in the background."
        case .memoryPressure:
            "\(app) is a major contributor to current memory pressure."
        case .wakeupStorm:
            "\(app) is waking the processor unusually often."
        case .sleepPrevention:
            "\(app) is preventing your Mac from sleeping."
        }
    }

    public var title: String {
        switch self {
        case .sustainedEnergy: "High energy use"
        case .hiddenBackgroundLoad: "Background activity"
        case .memoryPressure: "Memory pressure"
        case .wakeupStorm: "Frequent wakeups"
        case .sleepPrevention: "Preventing sleep"
        }
    }

    public var symbolName: String {
        switch self {
        case .sustainedEnergy: "bolt.fill"
        case .hiddenBackgroundLoad: "moon.fill"
        case .memoryPressure: "memorychip.fill"
        case .wakeupStorm: "waveform.path.ecg"
        case .sleepPrevention: "eye.fill"
        }
    }

    /// Section 5.9: this rule is specified but cannot yet be evidenced honestly.
    public var isAvailable: Bool { self != .sleepPrevention }
}

public enum InsightSeverity: String, Sendable, Codable {
    case info
    case warning

    public var label: String {
        switch self {
        case .info: "Notice"
        case .warning: "Warning"
        }
    }
}

/// One raised insight. `evidence` records the numbers that triggered it so the claim
/// can always be justified rather than merely asserted.
public struct Insight: Sendable, Identifiable, Equatable {
    public let id: String
    public let rule: InsightRule
    public let appGroupID: ApplicationGroupID
    public let appName: String
    public let startedAt: Date
    public let severity: InsightSeverity
    public let evidence: String

    public init(
        rule: InsightRule, appGroupID: ApplicationGroupID, appName: String,
        startedAt: Date, severity: InsightSeverity, evidence: String
    ) {
        // One live insight per rule per app: the same condition continuing is the
        // same insight, not a new one (Section 4.2 requires deduplication).
        self.id = "\(rule.rawValue):\(appGroupID.storageKey)"
        self.rule = rule
        self.appGroupID = appGroupID
        self.appName = appName
        self.startedAt = startedAt
        self.severity = severity
        self.evidence = evidence
    }

    public var message: String { rule.message(for: appName) }
}
