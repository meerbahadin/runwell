import Foundation
import UserNotifications
import PowerTaskKit

/// Section 2.1: notify about sustained high measured app energy, memory pressure and
/// background activity.
///
/// Section 9.1: these are local notifications only. Nothing is sent anywhere; the
/// system delivers them on this Mac.
final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()

    private var isAuthorized = false
    private var hasRequested = false
    /// Section 4.2 requires deduplication: the same rule for the same app should not
    /// notify repeatedly just because the condition is still true.
    private var lastNotified: [String: Date] = [:]
    private let repeatInterval: TimeInterval = 1800

    /// A burst of alerts is worse than none: under a heavy workload many apps cross a
    /// threshold within seconds of each other, and one notification per app turns a
    /// useful signal into a wall of banners. At most one notification per window, for
    /// the most significant condition in it.
    private var lastAnyNotification: Date?
    private let minimumSpacing: TimeInterval = 300
    private var pending: [Insight] = []

    private init() {}

    /// Asked for on first use rather than at launch, so the prompt has context.
    func requestAuthorizationIfNeeded() {
        guard !hasRequested else { return }
        hasRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.isAuthorized = granted
        }
    }

    /// Posts at most one notification per spacing window. Several apps crossing a
    /// threshold together produce one banner naming the biggest offender, not one
    /// banner each.
    func post(_ insights: [Insight]) {
        guard !insights.isEmpty else { return }
        requestAuthorizationIfNeeded()
        guard isAuthorized else { return }

        let now = Date()

        // Drop anything already announced recently, so a continuing condition does
        // not re-announce itself every cycle.
        let fresh = insights.filter { insight in
            guard let last = lastNotified[insight.id] else { return true }
            return now.timeIntervalSince(last) >= repeatInterval
        }
        guard !fresh.isEmpty else { return }

        // Hold back until the spacing window has passed. The conditions are still
        // visible in the app; only the interruption is deferred.
        if let lastAny = lastAnyNotification, now.timeIntervalSince(lastAny) < minimumSpacing {
            return
        }

        // A warning outranks a notice; otherwise the longest-running condition wins,
        // since it is the one that has proven itself.
        let ranked = fresh.sorted { a, b in
            if a.severity != b.severity { return a.severity == .warning }
            return a.startedAt < b.startedAt
        }
        guard let lead = ranked.first else { return }

        for insight in fresh { lastNotified[insight.id] = now }
        lastAnyNotification = now

        let content = UNMutableNotificationContent()
        content.title = lead.rule.title
        content.body = lead.message
        // The evidence goes in the subtitle so the claim arrives with its reason.
        content.subtitle = fresh.count > 1
            ? "\(lead.evidence) (+\(fresh.count - 1) more in PowerTask)"
            : lead.evidence
        content.sound = nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: lead.id, content: content, trigger: nil)
        )
    }
}
