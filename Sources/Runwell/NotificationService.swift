import Foundation
import UserNotifications
import RunwellKit

/// Section 2.1: notify about sustained high measured app energy, memory pressure and
/// background activity.
///
/// Section 9.1: these are local notifications only. Nothing is sent anywhere; the
/// system delivers them on this Mac.
final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()

    /// Nil until the system has told us. Distinct from `false`: an answer we have
    /// not received yet must not be read as a refusal, which is what silently
    /// dropped every insight raised before the first callback landed.
    private var isAuthorized: Bool?
    /// Guarded by `queue` along with the rest of the mutable state.
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
    /// Insights raised before the authorization answer arrived, replayed once it does.
    private var pending: [Insight] = []
    /// Insights that arrived inside a spacing window, waiting for the next one.
    private var held: [Insight] = []
    /// `post` is called from the sampler and the authorization callback from a system
    /// queue, so the mutable state needs one owner.
    private let queue = DispatchQueue(label: "com.powertask.notifications")

    private init() {}

    /// Asked for on first use rather than at launch, so the prompt has context.
    ///
    /// The authorization answer arrives asynchronously, so this also replays the
    /// insights that were raised while we were still waiting — otherwise the first
    /// batch after launch is always lost, which is the common case: conditions are
    /// usually detected before the user has interacted with the app at all.
    func requestAuthorizationIfNeeded() {
        let shouldAsk: Bool = queue.sync {
            guard !hasRequested else { return false }
            hasRequested = true
            return true
        }
        guard shouldAsk else { return }

        // A previously granted authorization survives relaunch, so ask the system
        // what it already knows before prompting.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.resolveAuthorization(true)
            case .denied:
                self.resolveAuthorization(false)
            default:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        self.resolveAuthorization(granted)
                    }
            }
        }
    }

    /// Chooses what to announce and records the rate-limit state. Callers must
    /// already hold `queue`.
    private func pick(from insights: [Insight], now: Date) -> (lead: Insight, count: Int)? {
        // A warning outranks a notice; otherwise the longest-running condition wins,
        // since it is the one that has proven itself.
        guard let lead = insights.max(by: { a, b in
            if a.severity != b.severity { return b.severity == .warning }
            return a.startedAt > b.startedAt
        }) else { return nil }
        for insight in insights { lastNotified[insight.id] = now }
        lastAnyNotification = now
        return (lead, insights.count)
    }

    /// Bounds the held queue; the app always shows the full list regardless.
    private func trimHeld() {
        if held.count > 64 { held.removeFirst(held.count - 64) }
    }

    /// The last known answer, for Settings to explain why banners are not arriving.
    /// Nil while the system has not told us yet.
    var authorizationAnswer: Bool? { queue.sync { isAuthorized } }

    /// Records the answer and flushes anything held while it was unknown.
    private func resolveAuthorization(_ granted: Bool) {
        let deferred: [Insight] = queue.sync {
            isAuthorized = granted
            defer { pending.removeAll() }
            return granted ? pending : []
        }
        if !deferred.isEmpty { post(deferred) }
    }

    /// Posts at most one notification per spacing window. Several apps crossing a
    /// threshold together produce one banner naming the biggest offender, not one
    /// banner each.
    func post(_ insights: [Insight]) {
        // An empty batch is still a tick: it is the opportunity to release anything
        // held from an earlier spacing window.
        if insights.isEmpty, queue.sync(execute: { held.isEmpty }) { return }
        requestAuthorizationIfNeeded()

        // Hold, don't drop, while the authorization answer is still outstanding.
        let authorized: Bool? = queue.sync {
            if isAuthorized == nil {
                // Bounded so a permanently unanswered prompt cannot grow without limit.
                pending.append(contentsOf: insights)
                if pending.count > 64 { pending.removeFirst(pending.count - 64) }
            }
            return isAuthorized
        }
        guard let authorized, authorized else { return }

        let now = Date()

        // Decide under the queue: the rate-limit state is shared, and two cycles
        // racing here would each believe they were the first through the window.
        let selected: (lead: Insight, count: Int)? = queue.sync {
            // Drop anything already announced recently, so a continuing condition
            // does not re-announce itself every cycle.
            let fresh = insights.filter { insight in
                guard let last = lastNotified[insight.id] else { return true }
                return now.timeIntervalSince(last) >= repeatInterval
            }
            guard !fresh.isEmpty else { return nil }

            // Hold back until the spacing window has passed. "Deferred" has to mean
            // deferred: dropping here lost the insight for good, because the engine
            // reports transitions only and a condition that stays true never raises
            // again. A warning still preempts the window — a notice about wakeups
            // must not be able to silence a genuine energy warning behind it.
            if let lastAny = lastAnyNotification, now.timeIntervalSince(lastAny) < minimumSpacing {
                let urgent = fresh.filter { $0.severity == .warning }
                guard !urgent.isEmpty else {
                    held.append(contentsOf: fresh)
                    trimHeld()
                    return nil
                }
                // Anything non-urgent still waits its turn rather than being lost.
                held.append(contentsOf: fresh.filter { $0.severity != .warning })
                trimHeld()
                return pick(from: urgent, now: now)
            }

            // Anything held from an earlier window rides along with this one.
            let batch = fresh + held
            held.removeAll()
            return pick(from: batch, now: now)
        }
        guard let selected else { return }
        let lead = selected.lead
        let freshCount = selected.count

        let content = UNMutableNotificationContent()
        content.title = lead.rule.title
        content.body = lead.message
        // The evidence goes in the subtitle so the claim arrives with its reason.
        content.subtitle = freshCount > 1
            ? "\(lead.evidence) (+\(freshCount - 1) more in Runwell)"
            : lead.evidence
        content.sound = nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: lead.id, content: content, trigger: nil)
        )
    }
}
