import Foundation
import FirebaseAnalytics

/// Every analytics event and user property the app reports, in one place.
///
/// Views call these methods rather than Firebase directly, so the full taxonomy
/// stays reviewable in a single file and no Firebase types leak into the UI.
///
/// The app links `FirebaseAnalyticsCore` — the variant that never touches
/// `AdSupport.framework` — so nothing here can reach the IDFA and the app needs
/// no App Tracking Transparency prompt.
///
/// Firebase's limits, all respected below: at most 500 distinct event names and
/// 25 user properties; names ≤40 characters, alphanumeric + underscore, starting
/// with a letter, and never prefixed `firebase_`/`google_`/`ga_`; at most 25
/// parameters per event with string values ≤100 characters.
///
/// Nothing recorded here is personal data — only die types, counts, totals and
/// timings.
enum Analytics {

    // MARK: - Throwing

    /// How a throw was started. Worth knowing whether shake-to-throw and the
    /// long-press aim gesture actually earn their keep.
    enum ThrowSource: String {
        case tapFelt = "tap_felt"
        case tapDie = "tap_die"
        case shake = "shake"
        case drag = "drag"
    }

    static func diceThrown(source: ThrowSource, pool: [PooledDie]) {
        log("dice_thrown", [
            "source": source.rawValue,
            "pool_size": pool.count,
            "pool_label": poolLabel(pool)
        ])
    }

    /// Logged when the dice come to rest. `settle_ms` is the point of this event:
    /// it turns "the results feel slow" into something measurable across real
    /// devices, so the v1.1 speed-up can be confirmed rather than assumed.
    static func throwSettled(total: Int, poolSize: Int, settleMs: Int, timedOut: Bool) {
        log("throw_settled", [
            "total": total,
            "pool_size": poolSize,
            "settle_ms": settleMs,
            "timed_out": timedOut ? 1 : 0
        ])
    }

    // MARK: - Pool composition

    static func dieAdded(_ type: DieType, poolSizeAfter: Int) {
        log("die_added", ["die_type": type.rawValue, "pool_size_after": poolSizeAfter])
    }

    /// `method` distinguishes the drag-off-the-table gesture from the reset button.
    static func dieRemoved(_ type: DieType, method: String, poolSizeAfter: Int) {
        log("die_removed", [
            "die_type": type.rawValue,
            "method": method,
            "pool_size_after": poolSizeAfter
        ])
    }

    static func poolReset(poolSizeBefore: Int) {
        log("pool_reset", ["pool_size_before": poolSizeBefore])
    }

    // MARK: - Screens & features

    /// SwiftUI gets no automatic screen tracking, so screens are logged by hand.
    /// Uses Firebase's own recommended `screen_view` event rather than a custom
    /// name so it feeds the built-in engagement reports.
    static func screenView(_ name: String) {
        FirebaseAnalytics.Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name
        ])
    }

    static func historyOpened(throwCount: Int) {
        log("history_opened", ["throw_count": throwCount])
    }

    static func historyCleared() {
        log("history_cleared", [:])
    }

    static func rateAppTapped() {
        log("rate_app_tapped", [:])
    }

    /// `value` is stringified so sound/haptics/shake (booleans) and sensitivity
    /// (low/medium/high) can share one event name instead of burning four.
    static func settingChanged(_ setting: String, value: String) {
        log("settings_changed", ["setting": setting, "value": value])
    }

    // MARK: - User properties

    /// Slow-changing dimensions used to segment the events above.
    static func updateUserProperties(pool: [PooledDie],
                                     soundEnabled: Bool,
                                     hapticsEnabled: Bool,
                                     shakeEnabled: Bool,
                                     sensitivity: String) {
        set(String(soundEnabled), for: "sound_enabled")
        set(String(hapticsEnabled), for: "haptics_enabled")
        set(String(shakeEnabled), for: "shake_enabled")
        set(sensitivity, for: "shake_sensitivity")
        set(mostCommonType(pool)?.rawValue ?? "none", for: "favorite_die_type")
        set(poolSizeBucket(pool.count), for: "pool_size_bucket")
    }

    // MARK: - Helpers

    /// "2d6 + d20" — the same shape as `ThrowResult.poolLabel`, capped well under
    /// Firebase's 100-character limit for string parameter values.
    private static func poolLabel(_ pool: [PooledDie]) -> String {
        var counts: [DieType: Int] = [:]
        var order: [DieType] = []
        for die in pool {
            if counts[die.type] == nil { order.append(die.type) }
            counts[die.type, default: 0] += 1
        }
        let label = order
            .map { counts[$0]! > 1 ? "\(counts[$0]!)\($0.label)" : $0.label }
            .joined(separator: " + ")
        return String(label.prefix(100))
    }

    private static func mostCommonType(_ pool: [PooledDie]) -> DieType? {
        var counts: [DieType: Int] = [:]
        for die in pool { counts[die.type, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Bucketed rather than raw so this stays a low-cardinality segment.
    private static func poolSizeBucket(_ count: Int) -> String {
        switch count {
        case 0: "0"
        case 1: "1"
        case 2: "2"
        case 3...4: "3-4"
        case 5...7: "5-7"
        default: "8+"
        }
    }

    private static func log(_ name: String, _ parameters: [String: Any]) {
        FirebaseAnalytics.Analytics.logEvent(name, parameters: parameters.isEmpty ? nil : parameters)
    }

    private static func set(_ value: String, for name: String) {
        FirebaseAnalytics.Analytics.setUserProperty(value, forName: name)
    }
}
