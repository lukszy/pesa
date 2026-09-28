import Foundation

/// What the menu bar status item renders. Pure, so the behaviour a user would
/// otherwise have to observe by eye is testable. Task 12 renders the result.
enum MenuBarPresentation {
    static func of(showMoney: Bool, showIcon: Bool, balance: Double?, error: Bool)
        -> (text: String?, symbol: String?) {
        // A status item with neither text nor image has nothing to click, which
        // would leave the app running but unreachable. The icon is the fallback.
        let symbol: String? = (showIcon || !showMoney) ? "dollarsign.circle" : nil

        let text: String?
        if !showMoney {
            text = nil
        } else if error {
            text = "—"
        } else if let balance {
            text = String(format: "$%.2f", balance)
        } else {
            // Never fetched: render nothing rather than a $0.00 lie.
            text = nil
        }
        return (text: text, symbol: symbol)
    }
}

/// Whether to raise a low-balance notification. Pure: the caller owns `Date()`
/// and any previous-balance state.
enum BalanceAlert {
    /// Fires on a crossing, never on a state. The app refetches every ten
    /// minutes, so a state rule would notify all day.
    static func shouldNotify(previous: Double?, current: Double?, threshold: Double,
                             enabled: Bool, authorized: Bool) -> Bool {
        guard enabled, authorized,
              let previous, previous >= threshold,
              let current, current < threshold
        else { return false }
        return true
    }
}
