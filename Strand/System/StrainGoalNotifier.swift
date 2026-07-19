import Foundation
import UserNotifications

/// Surfaces a "Target Strain Reached" notification once per day — the WHOOP-native celebratory nudge
/// (#593) NOOP was missing. Mirrors `BatteryNotifier`/`IllnessNotifier`: point-in-time post gated on
/// notification-authorization status at fire time, gated behind the user's "Strain goal" setting
/// (default OFF, opt-in like every automation here). On-device only.
///
/// HONEST about scope: the official app's copy ("...for this activity!") implies a per-activity target
/// from an undocumented proprietary model. NOOP has no visibility into that. Instead this fires against
/// the day's recovery-based OPTIMAL STRAIN floor (`AppModel.optimalStrainRange(recovery:).lowerBound`) —
/// the one target NOOP can actually compute, and the copy below says "today", not "for this activity",
/// so it never claims more precision than NOOP has.
enum StrainGoalNotifier {
    private static let alertedDayKey = "behavior.strainGoalAlertedDay"

    /// Pure crossing policy: fires at most once per calendar day, the moment `strain` first reaches
    /// `targetStrain`. `alertedDay` is the last day a fire was recorded (nil if never); comparing against
    /// `day` (not a boolean) means a new day always re-arms without needing an explicit midnight reset.
    enum StrainGoalPolicy {
        static func evaluate(day: String, strain: Double?, targetStrain: Double?, alertedDay: String?)
            -> (fire: Bool, newAlertedDay: String?) {
            guard let strain, let targetStrain, strain >= targetStrain, alertedDay != day else {
                return (false, alertedDay)
            }
            return (true, day)
        }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evaluate today's row and fire if the policy says to. `enabled` is the caller-owned
    /// `BehaviorStore.strainGoalAlerts` toggle, so a disabled automation never persists a crossing (a
    /// later enable re-arms honestly against that day's real state, not a stale flag from while it was
    /// off).
    static func onStrainUpdate(day: String, strain: Double?, targetStrain: Double?, enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let alertedDay = d.string(forKey: alertedDayKey)
        let decision = StrainGoalPolicy.evaluate(day: day, strain: strain, targetStrain: targetStrain,
                                                 alertedDay: alertedDay)
        guard decision.fire else { return }
        d.set(decision.newAlertedDay, forKey: alertedDayKey)
        post(day: day, strain: strain ?? 0)
    }

    private static func post(day: String, strain: Double) {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when the toggle is enabled; here
        // we only check status so a revoked permission can't queue an undeliverable notification.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Target Strain Reached")
            content.body = String(format: String(localized: "You've hit your target Strain of %.1f for today!"), strain)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "strain-goal-\(day)", content: content, trigger: nil))
        }
    }
}
