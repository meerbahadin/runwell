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

    private init() {}

    /// Asked for on first use rather than at launch, so the prompt has context.
    func requestAuthorizationIfNeeded() {
        guard !hasRequested else { return }
        hasRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.isAuthorized = granted
        }
    }

    func post(_ insight: Insight) {
        requestAuthorizationIfNeeded()
        guard isAuthorized else { return }

        if let last = lastNotified[insight.id],
           Date().timeIntervalSince(last) < repeatInterval {
            return
        }
        lastNotified[insight.id] = Date()

        let content = UNMutableNotificationContent()
        content.title = insight.rule.title
        content.body = insight.message
        // The evidence goes in the subtitle so the claim arrives with its reason.
        content.subtitle = insight.evidence
        content.sound = nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: insight.id, content: content, trigger: nil)
        )
    }
}
