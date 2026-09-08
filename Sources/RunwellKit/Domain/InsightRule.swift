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
    /// Section 5.9 / 8.3. Enabled once IOPMCopyAssertionsByProcess proved to be a
    /// supported, unprivileged source that attributes assertions to a pid, which is
    /// the condition the specification set for shipping this rule.
    case sleepPrevention

    /// How long the condition must hold before the insight is raised (Section 8.3).
    public var sustainedFor: TimeInterval {
        switch self {
        case .sustainedEnergy: 60
        case .hiddenBackgroundLoad: 120
        case .memoryPressure: 60
        case .wakeupStorm: 60
        // Long, on purpose. A brief assertion around finishing a task is normal;
        // what matters is one still held minutes after the screen went dark.
        case .sleepPrevention: 300
        }
    }

    /// Section 8.3's user wording, with the app name substituted. Each message names the *consequence* the reader
    /// cares about — battery, responsiveness — rather than the mechanism that was
    /// measured. "Waking the processor" is the reading; "draining the battery" is
    /// what it means, and the mechanism belongs in the evidence line beneath.
    public func message(for app: String) -> String {
        switch self {
        case .sustainedEnergy:
            "\(app) is using a lot of power."
        case .hiddenBackgroundLoad:
            "\(app) is using power in the background."
        case .memoryPressure:
            "\(app) is using a lot of memory and slowing your Mac down."
        case .wakeupStorm:
            "\(app) is draining the battery even when it looks idle."
        case .sleepPrevention:
            "\(app) is keeping your Mac awake."
        }
    }

    public var title: String {
        switch self {
        case .sustainedEnergy: "Heavy battery use"
        case .hiddenBackgroundLoad: "Draining in the background"
        case .memoryPressure: "Using a lot of memory"
        case .wakeupStorm: "Hidden battery drain"
        case .sleepPrevention: "Keeping your Mac awake"
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

    /// Every rule now has a validated source. Availability on a given Mac is decided
    /// by the capability probe at runtime, not here.
    public var isAvailable: Bool { true }

    /// Which story about an app is worth telling when several rules fire at once.
    /// One app must produce one row: measured power is the most direct statement of
    /// battery cost, so it outranks the proxies that merely predict it.
    public var priority: Int {
        switch self {
        case .sustainedEnergy: 5
        // Above the proxies: an app holding the machine awake is a concrete,
        // actionable cause, and the one the user can do something about. Below
        // measured power, which is the more direct statement of battery cost.
        case .sleepPrevention: 4
        case .hiddenBackgroundLoad: 3
        case .memoryPressure: 2
        case .wakeupStorm: 1
        }
    }
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
