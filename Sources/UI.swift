import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// The one place a remaining balance becomes display text. Four surfaces render
/// it — the menu bar, the popover header, the key-test status line, and the
/// low-balance notification — and a second formatter is how they drift apart.
func formatBalance(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

/// Compact per-million-token price. This reuses `formatBalance` rather than
/// opening a second `$%.2f`: a price and a balance can never format
/// differently.
func formatPerMillionTokens(_ pricePerToken: Double) -> String {
    formatBalance(pricePerToken * 1_000_000)
}

/// Human token count for the context window: 1_000_000 -> "1M",
/// 200_000 -> "200k". Anything not a whole thousand is shown raw.
func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 && count % 1_000_000 == 0 { return "\(count / 1_000_000)M" }
    if count >= 1_000 && count % 1_000 == 0 { return "\(count / 1_000)k" }
    return "\(count)"
}

/// An endpoint's `throughput_last_30m.p50` in tokens per second. `nil` means
/// the provider reported no throughput; it must render as omitted, never as
/// "0 tok/s".
func formatThroughput(_ tokensPerSecond: Double?) -> String? {
    guard let tokensPerSecond else { return nil }
    return String(format: "%.0f tok/s", tokensPerSecond)
}

/// An endpoint's `latency_last_30m.p50`. The schema documents milliseconds,
/// but its own example (0.25 for GPT-4 time-to-first-token) only reads as
/// seconds, so the unit is ambiguous. Rather than trust either reading, treat
/// values below 5 as seconds and 5 or above as milliseconds.
/// ponytail: magnitude heuristic for a doc-vs-example unit mismatch; replace
/// with the single unit once the API settles on one.
func formatLatency(_ p50: Double?) -> String? {
    guard let p50 else { return nil }
    if p50 < 5 { return String(format: "%.2f s", p50) }
    return String(format: "%.0f ms", p50)
}

/// SwiftUI's `Table` has no row-hover effect, so a cell's hover moves the
/// table's single selection to that row, which draws the native full-row
/// highlight. Cells only ever set it; the table clears it when the pointer
/// leaves, so moving between the cells of one row does not flicker.
private struct HoverSelectRow: ViewModifier {
    let id: String
    let hovered: Binding<String?>

    func body(content: Content) -> some View {
        content.onHover { over in
            if over { hovered.wrappedValue = id }
        }
    }
}

/// A harness row's one-line model text: `provider/model`, or `unset` when the
/// harness has no model configured. Shared by the popover tile and the Settings
/// harness row so the two cannot drift.
func formatHarnessModel(_ state: ToolState) -> String {
    if case .configured(let ref) = state { return "\(ref.provider)/\(ref.model)" }
    return "unset"
}

/// One stat card in the popover's grid below the balance. `progressRemaining`
/// and `progressTotal` are set only on the key-limit card, which draws a thin
/// bar; every other card leaves them nil.
struct StatTile: Equatable {
    let title: String
    let value: String
    var caption: String? = nil
    var progressRemaining: Double? = nil
    var progressTotal: Double? = nil
}

/// The popover's stat tiles, in display order. Every datum is optional at the
/// source, so a tile appears only when its figure is present — never as a `0`.
/// `now` is a parameter so the key-expiry tile is checkable without a clock.
///
/// Two families, and the titles keep them apart: the per-key tiles ("Today",
/// "Week", "Month", "Key limit", "BYOK", "Free models", "Key") come from
/// `/key`, and "Account spent" from `/credits`. With more than one key the per-
/// key figures do not reconcile with the account-wide one.
func widgetTiles(credits: Credits?, usage: KeyUsage?, now: Date) -> [StatTile] {
    var tiles: [StatTile] = []
    if let usage {
        if usage.isFreeTier == true {
            tiles.append(StatTile(title: "Tier", value: "free"))
        }
        // OpenRouter's day/week/month windows are **UTC** (daily resets at UTC
        // midnight, weekly is Monday–Sunday UTC), so the titles say so rather
        // than implying the user's local day.
        tiles.append(StatTile(title: "Today (UTC)", value: formatBalance(usage.usageDaily)))
        tiles.append(StatTile(title: "Week (UTC)", value: formatBalance(usage.usageWeekly)))
        tiles.append(StatTile(title: "Month (UTC)", value: formatBalance(usage.usageMonthly)))
        if let progress = usage.limitProgress {
            let reset = usage.limitReset.map { " · resets \($0)" } ?? ""
            tiles.append(StatTile(
                title: "Key limit",
                value: formatBalance(progress.remaining),
                caption: "of \(formatBalance(progress.total))\(reset)",
                progressRemaining: progress.remaining,
                progressTotal: progress.total))
        }
        // Account spent sits next to Key limit so the two half-width tiles share
        // a row (see `statRows`).
        tiles.append(contentsOf: accountTiles(credits))
        if let byok = usage.byokUsage, byok > 0 {
            tiles.append(StatTile(title: "BYOK", value: formatBalance(byok),
                                  caption: "own provider keys"))
        }
        if let expiry = expiryTile(usage, now: now) { tiles.append(expiry) }
    } else {
        tiles.append(contentsOf: accountTiles(credits))
    }
    return tiles
}

/// The account-wide tile, or none when nothing has been purchased (the share
/// would be undefined). Separate so it can be placed without a usage payload.
private func accountTiles(_ credits: Credits?) -> [StatTile] {
    guard let credits, credits.totalCredits > 0 else { return [] }
    let percent = Int((credits.totalUsage / credits.totalCredits * 100).rounded())
    return [StatTile(
        title: "Account spent",
        value: formatBalance(credits.totalUsage),
        caption: "\(percent)% of \(formatBalance(credits.totalCredits))")]
}

/// The key's expiry as a tile, but only when it is worth flagging: expired, or
/// inside 30 days. `nil` otherwise, including when the key never expires.
private func expiryTile(_ usage: KeyUsage, now: Date) -> StatTile? {
    guard let expires = usage.expiresAt else { return nil }
    // Direct date comparison: `dateComponents(.day)` truncates toward zero, so
    // an expiry an hour ago would read as 0 and show "expires in 0d".
    if expires <= now { return StatTile(title: "Key", value: "expired") }
    let days = Calendar.current.dateComponents([.day], from: now, to: expires).day ?? 0
    guard days <= 30 else { return nil }
    return StatTile(title: "Key", value: "expires in \(days)d")
}

/// How many of the grid's four columns a tile spans. Key limit and Account
/// spent are the wide ones; everything else is a single column.
func statSpan(_ tile: StatTile) -> Int {
    (tile.title == "Key limit" || tile.title == "Account spent") ? 2 : 1
}

/// Packs the tiles into display rows. Narrow tiles go four to a row; a wide tile
/// starts its own row and is joined by the next wide tile if one follows, so Key
/// limit and Account spent share one half-and-half row. Pure, so the layout rule
/// is checked.
func statRows(_ tiles: [StatTile]) -> [[StatTile]] {
    var rows: [[StatTile]] = []
    var row: [StatTile] = []
    var rowHasWide = false

    func flush() {
        if !row.isEmpty { rows.append(row) }
        row = []
        rowHasWide = false
    }

    for tile in tiles {
        if statSpan(tile) == 2 {
            if rowHasWide {
                row.append(tile)   // pair the two wide tiles and close the row
                flush()
            } else {
                flush()
                row = [tile]
                rowHasWide = true
            }
            continue
        }
        // A wide tile waiting for a partner takes its row alone; a narrow tile
        // after it starts a fresh row.
        if rowHasWide { flush() }
        row.append(tile)
        if row.count == 4 { flush() }
    }
    flush()
    return rows
}

/// The harness window's one-line model summary, e.g.
/// `1M context · $3.00/M in · $15.00/M out`. Each part is omitted when its
/// datum is missing, and `nil` means there is nothing to show at all. These
/// are the **base** rates: `/models` also carries tiered `overrides`, so the
/// line must not be read as the only rate.
func formatModelDetail(_ detail: ModelDetail) -> String? {
    var parts: [String] = []
    if let context = detail.contextLength { parts.append("\(formatTokenCount(context)) context") }
    if let prompt = detail.promptPricePerToken { parts.append("\(formatPerMillionTokens(prompt))/M in") }
    if let completion = detail.completionPricePerToken { parts.append("\(formatPerMillionTokens(completion))/M out") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// What the menu bar status item renders. Pure, so the behaviour a user would
/// otherwise have to observe by eye is testable. `StatusItemController` renders
/// the result.
enum MenuBarPresentation {
    /// `redacted` replaces only the formatted amount with dots; the `—` error
    /// indicator and the never-fetched `nil` case stay exactly as they are,
    /// because neither reveals a figure. Defaulted so every existing caller and
    /// check compiles unchanged, and so the setting off is the default.
    static func of(showMoney: Bool, showIcon: Bool, balance: Double?, error: Bool,
                   redacted: Bool = false)
        -> (text: String?, symbol: String?) {
        let text: String?
        if !showMoney {
            text = nil
        } else if error {
            text = "—"
        } else if let balance {
            text = redacted ? "...$" : formatBalance(balance)
        } else {
            // Never fetched: render nothing rather than a $0.00 lie.
            text = nil
        }

        // A status item with neither text nor image has nothing to click, which
        // would leave the app running but unreachable. Derive the fallback from
        // `text`, not from `showMoney`: money-on/icon-off with no balance yet is
        // reachable (a fetch in flight leaves error false and balance nil).
        let symbol: String? = (showIcon || text == nil) ? "dollarsign.circle" : nil
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

/// Which config edits require rebuilding the tool rows. Only the harness set
/// (`addedHarnesses`) feeds a row: `adapter.state()` can spawn a CLI, so
/// rebuilding on an interval, threshold, toggle, or launch-at-login edit freezes
/// the UI per keystroke. Pure, so the decision is testable without an `AppState`
/// or a real tool install.
enum ConfigChange {
    static func affectsRows(from old: AppConfig, to new: AppConfig) -> Bool {
        old.addedHarnesses != new.addedHarnesses
    }
}

/// The UI projection of one detected adapter. A row whose config could not be
/// read carries `.unset` and is excluded from the grid; `AppState.rowErrors`
/// carries the problem.
struct ToolRow {
    let id: String
    let displayName: String
    let symbol: String
    let state: ToolState
    let providers: [String]
}

/// Which detected harnesses render as tiles. A tile needs both halves of the
/// opt-in rule: the user added the harness, **and** discovery read it. A failed
/// harness is dropped from the grid entirely rather than shown as a broken row;
/// its count drives the popover's subdued footer so the failure is not silent.
/// Pure, so the visibility rule is pinned by checks instead of by eye. `failed`
/// is `AppState.rowErrors`, keyed by adapter id.
enum HarnessTiles {
    /// A tile renders only when the user added the harness **and** discovery
    /// read it. Membership alone is not enough: a failed harness must not
    /// reappear as a broken tile.
    static func visible(rows: [ToolRow], added: Set<String>, failed: [String: String]) -> [ToolRow] {
        rows.filter { added.contains($0.id) && failed[$0.id] == nil }
    }

    /// Failures that correspond to a row — i.e. the tiles actually excluded by
    /// failure. Counting `failed.count` would also include failures for hidden
    /// tools; deriving it from the healthy rows keeps it independent of
    /// `added`, so a failed harness is reported whether or not it was added.
    static func failedCount(rows: [ToolRow], failed: [String: String]) -> Int {
        rows.count - rows.filter { failed[$0.id] == nil }.count
    }
}

/// The result of one off-main discovery pass: plain values only, so it can
/// cross from the background task back to the main actor in one hop.
struct DiscoveryOutcome {
    var providers: [String: [String]]
    var rows: [ToolRow]
    var errors: [String: String]
}

/// Builds the provider cache and tool rows. Deliberately not actor-isolated:
/// `detect()`, `state()` and `providers()` touch only the filesystem and the
/// adapters' non-main-actor closures. `CatalogCache` and `ToolAdapter.models`
/// are `@MainActor` and are never reached from here, so this can run in a
/// detached task without annotation changes.
func discoverAdapters(_ adapters: [ToolAdapter]) -> DiscoveryOutcome {
    var providers: [String: [String]] = [:]
    for adapter in adapters where adapter.detect() {
        if let list = try? adapter.providers() {
            providers[adapter.id] = list
        }
    }

    var rows: [ToolRow] = []
    var errors: [String: String] = [:]
    for adapter in Tools.detected(adapters) {
        do {
            let toolState = try adapter.state()
            rows.append(ToolRow(
                id: adapter.id,
                displayName: adapter.displayName,
                symbol: adapter.symbol,
                state: toolState,
                providers: providers[adapter.id] ?? []))
        } catch {
            // Unreadable config: keep the row so the failure can be counted,
            // but `HarnessTiles.visible` excludes it from the grid. The popover
            // shows only the footer count; Settings renders the error text
            // beside the harness row.
            errors[adapter.id] = describeError(error)
            rows.append(ToolRow(
                id: adapter.id,
                displayName: adapter.displayName,
                symbol: adapter.symbol,
                state: .unset,
                providers: []))
        }
    }
    return DiscoveryOutcome(providers: providers, rows: rows, errors: errors)
}

/// Human-readable error text. Never includes key material: no error from the
/// network or the Keychain carries the credential. Free function so the
/// off-main discovery path can use the same mapping as `AppState.describe`.
func describeError(_ error: Error) -> String {
    if let openRouter = error as? OpenRouterError {
        switch openRouter {
        case .badStatus(let status):
            // The two statuses a user can act on get their own sentence; the
            // rest keep the bare code so it is never guessed at.
            switch status {
            case 401: return "OpenRouter rejected the API key (HTTP 401). Check it in Settings."
            case 402: return "OpenRouter returned HTTP 402 — the account or this key is out of credit."
            case 403: return "OpenRouter returned HTTP 403 — the key is not allowed to make this request."
            case 429: return "OpenRouter returned HTTP 429 — rate limited. It will clear on its own."
            default: return "OpenRouter returned HTTP \(status)."
            }
        case .notJSON: return "OpenRouter sent a response this app could not read."
        case .missingField(let field): return "OpenRouter's response was missing \(field)."
        }
    }
    // A failed URLSession request. The raw `URLError` description is a domain,
    // a code and a key, which is not something to show a user, so each common
    // case gets a plain sentence; anything else keeps the system's text.
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet:
            return "No internet connection."
        case .timedOut:
            return "The request to OpenRouter timed out."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
            return "Could not reach openrouter.ai. Check your connection."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return "Could not open a secure connection to OpenRouter."
        case .cancelled:
            return "The request was cancelled."
        default:
            return "Network error: \(urlError.localizedDescription)"
        }
    }
    return String(describing: error)
}

/// The app's observable state. `@MainActor` because its `@Published` properties
/// are mutated from a timer callback and from `URLSession` continuations,
/// neither of which runs on the main thread; SwiftUI updates off-main are
/// undefined and can crash. Every mutation of `remaining` / `lastUpdated` /
/// `errorText` / `rows` happens on this actor.
@MainActor
final class AppState: ObservableObject {
    static let keychainAccount = "openrouter"

    /// The one instance the app runs on. `AppDelegate` and the `Settings` scene
    /// must observe the same state; the delegate's property is not reliably
    /// ready when the scene body is first evaluated, so the instance is made
    /// explicit here. `init(paths:)` stays available for `SelfTest` and other
    /// harnesses that inject paths.
    @MainActor static let shared = AppState()

    @Published var remaining: Double?
    /// The last successful `/credits` result, so the popover can show spend of
    /// purchased credits as well as the remaining balance. Kept on a failed
    /// fetch, exactly like `remaining`.
    @Published var accountCredits: Credits?
    /// Per-key usage from `/api/v1/key`, or nil when it is unavailable. Read
    /// only by the popover's usage line; a failed `/key` must not fail the
    /// refresh or blank the account-wide balance above it.
    @Published var keyUsage: KeyUsage?
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var rows: [ToolRow] = []
    /// True while an async discovery pass is in flight, so the popover can show
    /// a subdued placeholder instead of an empty box.
    @Published var isDiscovering = false
    /// False until the first discovery pass finishes. The popover shows the
    /// in-flight placeholder when discovery is running **or** has never
    /// completed, so the very first open (before the pass at main.swift's
    /// `togglePopover` starts) cannot briefly claim no tools were detected.
    /// Deliberately not the guard input: `discoverProviders` gates on
    /// `isDiscovering` alone, so seeding this true cannot wedge discovery.
    @Published var hasCompletedDiscovery = false

    /// Persisted user settings. `didSet` writes them through and re-arms the
    /// refresh timer, so the UI binds directly and every change is saved. Rows
    /// are rebuilt only when a field that feeds a row changed: `adapter.state()`
    /// can spawn a CLI, and rebuilding on every keystroke in the interval,
    /// threshold, or toggle fields would freeze the UI.
    @Published var config: AppConfig {
        didSet {
            do {
                try config.save()
            } catch {
                errorText = "Could not save settings: \(describe(error))"
            }
            startRefreshTimer()
            if ConfigChange.affectsRows(from: oldValue, to: config) {
                Task { await discoverProviders() }
            }
        }
    }

    @Published var apiKeyInput = ""
    @Published var hasKey = false
    @Published var keyStatus: String?
    /// Whether the Settings window shows its sidebar. Driven by the window's
    /// title-bar toolbar (see `SettingsToolbarDelegate`), so it lives here rather
    /// than as view `@State`.
    @Published var showSidebar = true
    @Published var alertAuthorized = false
    @Published var authorizationStatusText = "Checking…"
    @Published var launchAtLoginError: String?
    @Published var toolErrorText: String?
    @Published var rowErrors: [String: String] = [:]

    private let paths: ToolPaths
    private var providerCache: [String: [String]] = [:]
    /// One-hour in-memory cache of endpoint facts, keyed by model id. The data
    /// is volatile and small, so it is never written to disk.
    private var endpointsCache: [String: (fetchedAt: Date, endpoints: [EndpointInfo])] = [:]
    private var endpointsTask: Task<Void, Never>?
    /// The Keychain backend is read at most once per launch (macOS prompts per
    /// access until the item's ACL trusts the app's signature); the file backend
    /// needs no cache. Reset whenever the key or the backend changes.
    private var cachedKeychainKey: String?
    private var didReadKeychain = false
    /// The ref the editor last wrote (or opened with). An unchanged selection is
    /// never written back, so opening the editor does not rewrite the config.
    private var lastEditRef: ToolModelRef?
    /// True while the editor seeds or re-seeds its fields, so seeding is not
    /// treated as a user edit — otherwise opening an unset harness would write
    /// the first catalog model into its config with no user action.
    private var isConfiguringEditor = false
    private var previousBalance: Double?
    private var refreshTimer: Timer?
    private var isRefreshing = false
    /// Set when a discovery request lands mid-pass, so the newer settings are
    /// picked up instead of being dropped as stale.
    private var discoveryPending = false
    init(paths: ToolPaths = .real) {
        self.paths = paths
        self.config = AppConfig.load()
        // Materialise `~/.pesa-app/settings.json` on first run: it is the key's
        // home and is meant to be hand-editable, so it should exist even before
        // the user changes a setting. A failure here is not fatal — the next
        // `config` change retries — so it is silent.
        if !FileManager.default.fileExists(atPath: AppConfig.path) {
            try? self.config.save()
        }
        // Reading the Keychain only when that backend is selected, so the file
        // default never prompts.
        if self.config.keyStorage == .keychain {
            self.cachedKeychainKey = Keychain.get(account: Self.keychainAccount)
            self.didReadKeychain = true
        }
        self.hasKey = isUsableAPIKey(self.currentKey())
        startRefreshTimer()
        Task { await refreshAuthorizationStatus() }
    }

    /// The key from whichever store `config.keyStorage` selects. The Keychain is
    /// read at most once per launch; the file needs no cache.
    private func currentKey() -> String? {
        guard config.keyStorage == .keychain else { return config.apiKey }
        if !didReadKeychain {
            didReadKeychain = true
            cachedKeychainKey = Keychain.get(account: Self.keychainAccount)
        }
        return cachedKeychainKey
    }

    /// Human-readable name of the active store, for the Settings status line.
    var keyStorageDescription: String {
        switch config.keyStorage {
        case .file: return "~/.pesa-app/settings.json"
        case .keychain: return "the Keychain"
        }
    }

    /// Switches backend, carrying an existing key across so it is not lost, and
    /// clearing the store it came from so the key never lives in two places.
    func setKeyStorage(_ storage: KeyStorage) {
        guard storage != config.keyStorage else { return }
        let existing = currentKey()
        config.keyStorage = storage
        switch storage {
        case .file:
            if isUsableAPIKey(existing) { config.apiKey = existing }
            try? Keychain.delete(account: Self.keychainAccount)
            cachedKeychainKey = nil
            didReadKeychain = true
        case .keychain:
            if let existing, isUsableAPIKey(existing) {
                try? Keychain.set(existing, account: Self.keychainAccount)
                cachedKeychainKey = existing
            } else {
                cachedKeychainKey = nil
            }
            didReadKeychain = true
            if config.apiKey != nil { config.apiKey = nil }
        }
        hasKey = isUsableAPIKey(currentKey())
        keyStatus = nil
    }

    // MARK: - Adapters

    private var orderedAdapters: [ToolAdapter] { Tools.all(paths) }

    private var adaptersByID: [String: ToolAdapter] {
        Dictionary(uniqueKeysWithValues: orderedAdapters.map { ($0.id, $0) })
    }

    // MARK: - Refresh

    /// Fetches the balance and (best-effort) the model catalog. A failed catalog
    /// fetch must never fail the refresh: the picker simply keeps each tool's
    /// own configured models.
    func refresh() async {
        // A refresh can be re-entered at its awaits by the timer and the Refresh
        // button overlapping. Serializing here keeps `previousBalance` read and
        // written as one step, so a crossing is never double-posted or dropped.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if let catalog = try? await OpenRouter.models() {
            CatalogCache.entries = catalog.models
            // A body with no pricing falls back to detail-less entries;
            // assigning it would wipe prices that were already shown, so the
            // replace rule lives in the pure `mergeDetails`.
            CatalogCache.details = CatalogCache.mergeDetails(
                existing: CatalogCache.details, new: catalog.details)
        }

        // The key comes from the active store, so the guard and `hasKey` cannot
        // disagree.
        let storedKey = currentKey()
        hasKey = isUsableAPIKey(storedKey)
        guard isUsableAPIKey(storedKey), let key = storedKey else {
            errorText = "No OpenRouter API key. Add one in Settings."
            // A key removed outside the app (e.g. `security delete-generic-password`)
            // never passes through `clearKey()`, so without this the popover
            // keeps attributing the removed key's usage to the current key.
            keyUsage = nil
            return
        }
        do {
            let credits = try await OpenRouter.credits(apiKey: key)
            let balance = credits.remaining
            // The crossing decision lives only in BalanceAlert; this path must
            // not invent a second one.
            if BalanceAlert.shouldNotify(
                previous: previousBalance, current: balance,
                threshold: config.notifyBelowAmount,
                enabled: config.notifyBelowEnabled, authorized: alertAuthorized) {
                postLowBalanceNotification(balance: balance, threshold: config.notifyBelowAmount)
            }
            previousBalance = balance
            remaining = balance
            accountCredits = credits
            lastUpdated = Date()
            errorText = nil
        } catch {
            // Keep `remaining` and `lastUpdated`: the popover shows the last
            // known balance with its age; `MenuBarPresentation` turns the error
            // into the em dash on the status item.
            errorText = describe(error)
        }

        // Per-key usage is supplementary. It is fetched after the balance so a
        // failure here can never affect it, and a failure hides the line
        // rather than failing the refresh.
        do {
            keyUsage = try await OpenRouter.keyUsage(apiKey: key)
        } catch {
            keyUsage = nil
        }
    }

    // MARK: - Rows

    /// Discovers each detected tool's provider list and row state. The
    /// filesystem work runs in a detached task; only
    /// the finished values are merged here on the main actor. Called while the
    /// popover is open and whenever a row-affecting setting changes, never by
    /// the refresh timer. A request arriving mid-pass is coalesced into a
    /// re-run, so a fast typist's last keystroke is what the rows reflect. The
    /// guard never leaves the pass permanently wedged: the early return only
    /// sets a flag, and the running pass drains it.
    func discoverProviders() async {
        guard !isDiscovering else {
            discoveryPending = true
            return
        }
        isDiscovering = true
        defer { isDiscovering = false }
        repeat {
            discoveryPending = false
            let adapters = orderedAdapters
            let outcome = await Task.detached(priority: .userInitiated) {
                discoverAdapters(adapters)
            }.value

            providerCache = outcome.providers
            rowErrors = outcome.errors
            rows = outcome.rows
        } while discoveryPending
        hasCompletedDiscovery = true
    }

    func providers(forAdapterID id: String, current: String?) -> [String] {
        var providers = providerCache[id] ?? adaptersByID[id].flatMap { try? $0.providers() } ?? []
        if let current, !providers.contains(current) { providers.insert(current, at: 0) }
        return providers
    }

    func models(forAdapterID id: String, provider: String) -> [(id: String, name: String)] {
        guard let adapter = adaptersByID[id] else { return [] }
        return (try? adapter.models(provider)) ?? []
    }

    /// The OpenRouter catalog detail for a model id, or nil when the id is not
    /// in the fetched catalog — e.g. a locally configured non-OpenRouter
    /// model. The harness window shows nothing rather than a false figure.
    func modelDetail(for id: String) -> ModelDetail? {
        guard !id.isEmpty else { return nil }
        return CatalogCache.details[id]
    }

    func setModel(_ ref: ToolModelRef, for adapterID: String) {
        guard let adapter = adaptersByID[adapterID] else { return }
        do {
            try adapter.setModel(ref)
            toolErrorText = nil
            Task { await discoverProviders() }
        } catch {
            toolErrorText = "Could not update \(adapter.displayName): \(describe(error))"
        }
    }

    // MARK: - Model editor

    /// Editor state for the Agent Harnesses detail pane. It lives here rather
    /// than as `@State` in a view so the pane can be retargeted to another
    /// harness without rebuilding its content view.
    @Published var editAdapterID: String?
    @Published var editProvider = "" {
        // A provider change is a pair change: `selectProvider` writes it once the
        // model has been re-seeded, so a bare provider edit does not save here.
        didSet { refreshEditEndpoints() }
    }
    @Published var editModel = "" {
        didSet {
            refreshEditEndpoints()
            saveEditedModel()
        }
    }
    @Published var editProviders: [String] = []
    @Published var editModels: [(id: String, name: String)] = []
    /// Live OpenRouter per-provider facts for the selected model. Empty while a
    /// fetch is in flight and after one fails; the editor's base price line is
    /// independent, so a failure never blanks it.
    @Published var editEndpoints: [EndpointInfo] = []

    func beginEdit(_ row: ToolRow) {
        // Seeding the fields must not look like a user edit.
        isConfiguringEditor = true
        defer { isConfiguringEditor = false }

        editAdapterID = row.id
        let current: ToolModelRef?
        if case .configured(let ref) = row.state { current = ref } else { current = nil }
        lastEditRef = current
        editProviders = providers(forAdapterID: row.id, current: current?.provider)
        editProvider = current?.provider ?? editProviders.first ?? ""
        editModels = models(forAdapterID: row.id, provider: editProvider)
        editModel = current?.model ?? editModels.first?.id ?? ""
    }

    /// Selects a provider and the model it will use, then saves the pair once.
    /// The intermediate field assignments happen under `isConfiguringEditor` so
    /// the model change does not fire a second, torn save; one save of the final
    /// pair follows. Saving is synchronous, so nothing is lost to a debounce when
    /// the user switches harness or leaves immediately.
    func selectProvider(_ provider: String, for adapterID: String) {
        isConfiguringEditor = true
        editProvider = provider
        editModels = models(forAdapterID: adapterID, provider: provider)
        if !editModels.contains(where: { $0.id == editModel }) {
            editModel = editModels.first?.id ?? ""
        }
        isConfiguringEditor = false
        refreshEditEndpoints()
        saveEditedModel()
    }

    /// Loads the OpenRouter endpoint facts for the current editor selection.
    /// Served from the one-hour cache when fresh; otherwise one Task fetches
    /// and applies the result only if the model is still selected. No key, a
    /// non-OpenRouter provider, or any fetch failure leaves `editEndpoints`
    /// empty rather than failing the editor.
    private func refreshEditEndpoints() {
        guard editProvider == "openrouter" else {
            editEndpoints = []
            return
        }
        let modelID = editModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // A partial id being typed is not a model yet; wait for its slash.
        guard modelID.contains("/") else {
            editEndpoints = []
            return
        }
        if let cached = endpointsCache[modelID],
           Date().timeIntervalSince(cached.fetchedAt) < 60 * 60 {
            editEndpoints = cached.endpoints
            return
        }
        guard let key = currentKey(), isUsableAPIKey(key) else {
            editEndpoints = []
            return
        }
        editEndpoints = []
        endpointsTask?.cancel()
        endpointsTask = Task { [weak self] in
            let fetched = try? await OpenRouter.modelEndpoints(modelID: modelID, apiKey: key)
            guard let self, !Task.isCancelled else { return }
            let endpoints = fetched ?? []
            self.endpointsCache[modelID] = (fetchedAt: Date(), endpoints: endpoints)
            // A late reply for a model the user has since moved off must not
            // overwrite the current table.
            guard self.editProvider == "openrouter",
                  self.editModel.trimmingCharacters(in: .whitespacesAndNewlines) == modelID else { return }
            self.editEndpoints = endpoints
        }
    }

    /// Writes the current provider/model to the harness. A no-op when the pair is
    /// what the harness already has, so opening the editor never rewrites the
    /// file, and an empty or partially seeded pair is never written.
    private func saveEditedModel() {
        guard !isConfiguringEditor, let adapterID = editAdapterID else { return }
        let ref = ToolModelRef(provider: editProvider, model: editModel)
        guard !ref.provider.isEmpty, !ref.model.isEmpty, ref != lastEditRef else { return }
        lastEditRef = ref
        setModel(ref, for: adapterID)
    }

    /// Leaves the editor. Changes are saved as they are made, so this only clears
    /// the selection — it never writes (or discards) anything itself.
    func closeEdit() {
        editAdapterID = nil
        lastEditRef = nil
    }

    // MARK: - API key

    /// Writes the key to the active store. The file backend persists through the
    /// `didSet` on `config`; the Keychain backend talks to `Keychain` directly.
    /// The other store is cleared, so the key never lives in two places.
    func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyStatus = "Enter a key first."
            return
        }
        switch config.keyStorage {
        case .file:
            config.apiKey = key
            try? Keychain.delete(account: Self.keychainAccount)
            cachedKeychainKey = nil
            didReadKeychain = true
        case .keychain:
            do {
                try Keychain.set(key, account: Self.keychainAccount)
            } catch {
                keyStatus = "Could not save the key: \(describe(error))"
                return
            }
            cachedKeychainKey = key
            didReadKeychain = true
            if config.apiKey != nil { config.apiKey = nil }
        }
        apiKeyInput = ""
        hasKey = true
        // The previous key's per-key figures belong to a key that is no longer
        // stored; clear them so the popover cannot attribute them to the new key
        // until its own fetch lands.
        keyUsage = nil
        keyStatus = "Key saved to \(keyStorageDescription)."
    }

    func testKey() async {
        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (currentKey() ?? "") : typed
        guard isUsableAPIKey(key) else {
            keyStatus = "Enter a key first."
            return
        }
        do {
            let credits = try await OpenRouter.credits(apiKey: key)
            keyStatus = "Key works. Remaining \(formatBalance(credits.remaining))."
        } catch {
            keyStatus = "Key test failed: \(describe(error))"
        }
    }

    func clearKey() {
        // Clear both stores: a key left in the other one would reappear if the
        // backend were switched back.
        config.apiKey = nil
        try? Keychain.delete(account: Self.keychainAccount)
        cachedKeychainKey = nil
        didReadKeychain = true
        apiKeyInput = ""
        hasKey = false
        // `refresh()` returns early with no stored key, so without this the
        // removed key's usage line would stay on screen indefinitely.
        keyUsage = nil
        keyStatus = "Key removed."
    }

    // MARK: - Alerts

    func setAlertEnabled(_ enabled: Bool) {
        config.notifyBelowEnabled = enabled
        guard enabled else { return }
        Task { await requestNotificationAuthorization() }
    }

    func refreshAuthorizationStatus() async {
        guard notificationsAvailable else {
            alertAuthorized = false
            authorizationStatusText = "unavailable outside the app bundle"
            return
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        alertAuthorized = Self.isAuthorized(status)
        authorizationStatusText = Self.describe(status)
    }

    /// Requests permission only while it is still undetermined. A refused
    /// permission is never re-prompted and never fails a refresh.
    private func requestNotificationAuthorization() async {
        guard notificationsAvailable else {
            alertAuthorized = false
            authorizationStatusText = "unavailable outside the app bundle"
            return
        }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        alertAuthorized = Self.isAuthorized(status)
        authorizationStatusText = Self.describe(status)
    }

    private func postLowBalanceNotification(balance: Double, threshold: Double) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "OpenRouter balance is low"
        content.body = "Remaining \(formatBalance(balance)), below your \(formatBalance(threshold)) threshold."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        // Delivery is best-effort: a failed post must not fail the refresh.
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    /// `UNUserNotificationCenter.current()` raises an ObjC exception when the
    /// process is not inside an app bundle — exactly the raw `.build/` binary —
    /// so every UserNotifications entry point is guarded by this.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not requested yet"
        case .denied: return "denied in System Settings"
        case .authorized: return "allowed"
        case .provisional: return "provisional"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Launch at login

    /// `SMAppService.mainApp.register()` throws when the process is not a
    /// bundled app (running `.build/Pesa` directly), so the
    /// failure is surfaced and the setting is left unchanged rather than
    /// persisted as if it had worked.
    func setLaunchAtLogin(_ enabled: Bool) {
        // `SMAppService.mainApp.register()` is meaningless without an app
        // bundle: the raw `.build/` binary has none, so there is nothing for the
        // OS to launch at login. Surface that instead of persisting a setting
        // that cannot work. (On this SDK the call itself does not throw for a
        // non-bundled process, so the bundle check is what reports it.)
        guard Bundle.main.bundleIdentifier != nil else {
            launchAtLoginError = "Launch at login needs the .app built by scripts/build-app.sh."
            return
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status != .notRegistered { try service.unregister() }
            }
            config.launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not \(enabled ? "enable" : "disable") launch at login: "
                + "\(error.localizedDescription)"
        }
    }

    // MARK: - Timer

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(config.refreshMinutes, 1)) * 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Human-readable error text. Never includes key material: no error from
    /// the network carries the credential. A key loaded from the settings file
    /// is never logged or included in an error message.
    private func describe(_ error: Error) -> String {
        describeError(error)
    }
}

/// The popover: one scrolling page with a header, the detected tools, and a
/// collapsed Settings disclosure.
struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                toolList
                if let error = state.toolErrorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
        .frame(width: 380)
        // Tall enough for the amount, the updated line and the tile grid without
        // scrolling; the scroll view is only a fallback for a short screen.
        .frame(maxHeight: 720)
    }

    // MARK: Header

    private var header: some View {
        // The balance is the centrepiece. A never-fetched balance shows the em
        // dash in the same large style rather than a $0.00 lie; a failed fetch
        // keeps the last known balance large with the error beneath it. The
        // refresh control lives in an overlay pinned to the top-trailing
        // corner, so an HStack button can never push the number off-centre.
        VStack(spacing: 4) {
            // The popover always shows the balance, even when the menu bar
            // hides it. The status item's text comes from MenuBarPresentation,
            // not from this view.
            Text(balanceText)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .padding(.top, 18)
                .padding(.bottom, 18)
            // How fresh the figures are, directly under the amount and above the
            // tiles it describes.
            if let updated = state.lastUpdated {
                Text("Updated \(updated, style: .relative)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // The stats are tiles under the amount. Per-key tiles come from
            // `/key` and the account tile from `/credits`; the titles keep them
            // apart, because with more than one key the two do not reconcile.
            statTiles
            if let error = state.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }

    private var balanceText: String {
        guard let remaining = state.remaining else { return "—" }
        return formatBalance(remaining)
    }

    /// The stat tiles under the balance: four equal cards to a row, with the
    /// "Key limit" card on a full-width row of its own because it carries the
    /// bar and a longer caption. Empty (nothing) when no figure is known yet.
    @ViewBuilder
    private var statTiles: some View {
        let rows = statRows(widgetTiles(credits: state.accountCredits,
                                        usage: state.keyUsage, now: Date()))
        if !rows.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let hasWide = row.contains { statSpan($0) == 2 }
                    HStack(spacing: 8) {
                        ForEach(row, id: \.title) { statTile($0, wide: statSpan($0) == 2) }
                        // Clear fillers keep a short row's cards the same width
                        // as a full four-up row. A row that holds a wide tile is
                        // left unfilled, so two wide tiles split it in half.
                        if !hasWide {
                            ForEach(0..<(4 - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statTile(_ tile: StatTile, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tile.title).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tile.value).font(.callout).bold()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let caption = tile.caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(wide ? 1 : 2).minimumScaleFactor(0.7)
            }
            if let remaining = tile.progressRemaining,
               let total = tile.progressTotal, total > 0 {
                ProgressView(value: remaining, total: total)
                    .progressViewStyle(.linear)
            }
        }
        // A fixed minimum height makes every card the same size, whether or not
        // it has a caption.
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: Tools

    private var toolList: some View {
        // Opt-in: only harnesses the user added in Settings, and only the ones
        // discovery could read. Adding or removing one writes
        // `addedHarnesses`, whose `didSet` re-runs discovery.
        let visible = HarnessTiles.visible(
            rows: state.rows,
            added: Set(state.config.addedHarnesses),
            failed: state.rowErrors)
        let failed = HarnessTiles.failedCount(rows: state.rows, failed: state.rowErrors)
        return VStack(alignment: .leading, spacing: 8) {
            if state.isDiscovering || !state.hasCompletedDiscovery {
                // Discovery is asynchronous; while it is in flight — or before
                // the first pass has finished — the popover is already on
                // screen and this keeps it from looking empty. Gating on
                // `isDiscovering` alone would flash the empty state on the very
                // first open, before main.swift has started discovery.
                Text("Checking agents…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text("No harnesses added — add one in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ], spacing: 8) {
                    ForEach(visible, id: \.id) { row in
                        tile(row)
                    }
                }
            }
            // A harness that failed discovery is not a tile; this keeps the
            // failure from being silent without contradicting that rule.
            if failed > 0 {
                Text(failed == 1 ? "1 harness could not be read" : "\(failed) harnesses could not be read")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ row: ToolRow) -> some View {
        Button {
            state.beginEdit(row)
            SettingsWindow.open()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: row.symbol)
                    Text(row.displayName).font(.body).bold()
                }
                Text(formatHarnessModel(row.state)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

/// The model editor, hosted in the Settings window's detail pane (the same
/// window as the harness list, not a separate one). Reads and writes
/// `AppState`'s editor fields, so the detail pane can be retargeted to another
/// harness without keeping any state of its own.
struct ModelEditorView: View {
    @ObservedObject var state: AppState
    let row: ToolRow

    /// The "add a provider" empty-state flow. A fresh root view is built on each
    /// open, so this never leaks between harnesses.
    @State private var isAddingProvider = false
    @State private var providerDraft = ""
    /// The provider table's sort, driven by SwiftUI's `Table` column headers.
    /// Default provider-name ascending.
    @State private var sortOrder: [KeyPathComparator<EndpointInfo>] = [
        KeyPathComparator(\EndpointInfo.providerName),
    ]
    /// The hovered row's id, used as the table's selection so the pointer
    /// highlights a row (see `HoverSelectRow`).
    @State private var hoveredRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { state.closeEdit() } label: {
                    Label("Harnesses", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.symbol)
                    Text(row.displayName).font(.headline)
                }
            }
            providerControl
            // Searchable select: the dropdown filters as you type, and text that
            // matches no catalog model is still accepted as a free-form id.
            SearchablePicker(options: modelOptions, selection: $state.editModel)
            if let detail = state.modelDetail(for: state.editModel),
               let summary = formatModelDetail(detail) {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Base rates from OpenRouter's public model catalog. Tiered overrides above a prompt-token threshold are not shown.")
            }
            if state.editProvider == "openrouter" && !state.editModel.isEmpty {
                openRouterProviders
            }
            if let error = state.toolErrorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Changes are saved automatically.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        // Fill the pane: the provider Table takes the remaining height and
        // scrolls itself, so the content must be allowed to grow vertically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Provider selection

    /// Provider control. With providers configured it is a picker over them;
    /// with none it shows an explicit empty state whose Add button reveals a
    /// free-text field, so a harness with no configured provider is usable.
    @ViewBuilder
    private var providerControl: some View {
        if state.editProviders.isEmpty && state.editProvider.isEmpty && !isAddingProvider {
            HStack {
                Text("Provider")
                Spacer()
                Button("Add provider…") {
                    providerDraft = ""
                    isAddingProvider = true
                }
            }
        } else if isAddingProvider {
            HStack {
                TextField("provider name", text: $providerDraft)
                    .frame(minWidth: 260)
                    .onSubmit(addProvider)
                Button("Add", action: addProvider)
                    .disabled(providerDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { isAddingProvider = false }
            }
        } else {
            HStack {
                Text("Provider").frame(width: 64, alignment: .leading)
                Picker("", selection: Binding(
                    get: { state.editProvider },
                    set: { newValue in state.selectProvider(newValue, for: row.id) })) {
                    ForEach(providerOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    /// The picker's values: the detected providers plus the one currently set,
    /// so a configured provider that detection did not list stays visible.
    private var providerOptions: [String] {
        guard !state.editProvider.isEmpty,
              !state.editProviders.contains(state.editProvider) else { return state.editProviders }
        return [state.editProvider] + state.editProviders
    }

    /// Adds the typed provider to the session list, selects it, and loads its
    /// models. Nothing reaches the harness until Set, so a typo is just a wrong
    /// selection to correct.
    private func addProvider() {
        let name = providerDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !state.editProviders.contains(name) { state.editProviders.append(name) }
        state.selectProvider(name, for: row.id)
        isAddingProvider = false
    }

    // MARK: OpenRouter provider routing

    /// The live per-provider table plus the recorded allow-list. Rendered only
    /// for an OpenRouter model with a selection; a failed or empty fetch shows
    /// nothing rather than a row of zeros, and the base price line above stays
    /// untouched.
    @ViewBuilder
    private var openRouterProviders: some View {
        if !state.editEndpoints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Providers").font(.caption).bold()
                providerTable
                Text("Tick a provider to allow it (OpenRouter's provider.only). Recorded by this app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The endpoint rows, ordered by the `Table`'s current sort order. SwiftUI's
    /// `Table` reflects the order in its headers but leaves re-ordering to the
    /// caller, so the sort happens here.
    private var displayedEndpoints: [EndpointInfo] {
        state.editEndpoints.sorted(using: sortOrder)
    }

    private var providerTable: some View {
        Table(displayedEndpoints, selection: $hoveredRow, sortOrder: $sortOrder) {
            // Selection on the left, in the row it applies to. A checkbox is not
            // a value, so its column is deliberately unsortable.
            TableColumn("Allow") { endpoint in
                Toggle("", isOn: allowedBinding(for: endpoint.providerSlug))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Allow this provider for the model")
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            .width(52)
            TableColumn("Provider", value: \.providerName) { endpoint in
                Text(endpoint.providerName).lineLimit(1)
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            .width(min: 120, ideal: 160)
            TableColumn("In/M", value: \.promptOrder) { endpoint in
                Text(priceCell(endpoint.promptPricePerToken)).monospacedDigit()
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            TableColumn("Out/M", value: \.completionOrder) { endpoint in
                Text(priceCell(endpoint.completionPricePerToken)).monospacedDigit()
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            TableColumn("Speed", value: \.speedOrder) { endpoint in
                Text(speedCell(endpoint)).monospacedDigit()
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            TableColumn("ZDR", value: \.zdrOrder) { endpoint in
                Group {
                    if endpoint.zdr {
                        Text("ZDR")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.2)))
                    } else {
                        Text("—")
                    }
                }
                .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            .width(56)
            TableColumn("Quant", value: \.quantOrder) { endpoint in
                Text(endpoint.quantization ?? "—").lineLimit(1)
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
            .width(min: 60, ideal: 72)
            TableColumn("Links") { endpoint in
                providerLinks(endpoint)
                    .modifier(HoverSelectRow(id: endpoint.id, hovered: $hoveredRow))
            }
        }
        // The Table scrolls itself; let it take the pane's remaining height.
        .frame(minHeight: 180, maxHeight: .infinity)
        // Leaving the table clears the highlight; cells never clear it, so
        // crossing between a row's cells keeps it lit.
        .onHover { over in if !over { hoveredRow = nil } }
    }

    /// A missing price is an em dash, never `$0.00`.
    private func priceCell(_ pricePerToken: Double?) -> String {
        guard let pricePerToken else { return "—" }
        return formatPerMillionTokens(pricePerToken)
    }

    /// Throughput and latency, each omitted when the endpoint reported none.
    private func speedCell(_ endpoint: EndpointInfo) -> String {
        let parts = [formatThroughput(endpoint.throughputP50), formatLatency(endpoint.latencyP50)]
            .compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func providerLinks(_ endpoint: EndpointInfo) -> some View {
        HStack(spacing: 6) {
            if let privacy = endpoint.privacyPolicyURL, let url = URL(string: privacy) {
                Link("Privacy", destination: url)
            }
            if let tos = endpoint.termsOfServiceURL, let url = URL(string: tos) {
                Link("ToS", destination: url)
            }
            if endpoint.privacyPolicyURL == nil && endpoint.termsOfServiceURL == nil {
                Text("—")
            }
        }
    }

    /// The checked provider slugs: the stored list when present, otherwise all.
    private var checkedSlugs: Set<String> {
        let all = state.editEndpoints.map(\.providerSlug)
        guard let stored = state.config.providerOnly[state.editModel], !stored.isEmpty else {
            return Set(all)
        }
        return Set(stored)
    }

    /// One checkbox over the recorded allow-list. An absent or empty stored list
    /// means all checked; checking every box removes the key again so "all" is
    /// never stored explicitly.
    private func allowedBinding(for slug: String) -> Binding<Bool> {
        Binding(
            get: { checkedSlugs.contains(slug) },
            set: { isOn in
                var checked = checkedSlugs
                if isOn { checked.insert(slug) } else { checked.remove(slug) }
                let all = state.editEndpoints.map(\.providerSlug)
                if checked.isSuperset(of: all) {
                    state.config.providerOnly.removeValue(forKey: state.editModel)
                } else {
                    state.config.providerOnly[state.editModel] = all.filter { checked.contains($0) }
                }
            })
    }

    /// Keeps the current value selectable so the Picker never logs an invalid
    /// selection for a model that is not in the fetched list.
    private var modelOptions: [(id: String, name: String)] {
        guard !state.editModel.isEmpty,
              !state.editModels.contains(where: { $0.id == state.editModel }) else {
            return state.editModels
        }
        return [(id: state.editModel, name: state.editModel)] + state.editModels
    }
}

/// The settings content, shown in the SwiftUI `Settings` scene opened by the
/// status item's right-click `Settings…` item and the app menu's Settings…
/// item. Quit intentionally lives on the status item's right-click menu now,
/// not here.
/// One item of the Settings sidebar. `Hashable` so `List(selection:)` can use it.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, apiKey, menuBar, harnesses, alerts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .apiKey: return "API Key"
        case .menuBar: return "Menu Bar"
        case .harnesses: return "Agent Harnesses"
        case .alerts: return "Alerts"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .apiKey: return "key"
        case .menuBar: return "menubar.rectangle"
        case .harnesses: return "square.grid.2x2"
        case .alerts: return "bell"
        case .about: return "info.circle"
        }
    }
}

/// The settings window: a sidebar of sections on the left and one grouped-card
/// detail pane on the right, matching the macOS settings-window layout.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var section: SettingsSection? = .general

    var body: some View {
        HStack(spacing: 0) {
            if state.showSidebar {
                List(selection: $section) {
                    ForEach(SettingsSection.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 195)
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Settings is where a harness is added, so it must run the detection
        // pass itself instead of waiting for the popover to have been opened.
        // Idempotent: the guard skips a pass that already ran.
        .task {
            if !state.hasCompletedDiscovery { await state.discoverProviders() }
        }
        // A minimum plus an unbounded maximum: the window is made resizable in
        // `SettingsWindow.open`, and this lets the sidebar and detail pane fill
        // whatever size the user drags.
        .frame(minWidth: 720, idealWidth: 900, maxWidth: .infinity,
               minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        // The popover's tile and the harness list both start an edit; bring the
        // sidebar to the section whose pane shows the editor.
        .onAppear { if state.editAdapterID != nil { section = .harnesses } }
        .onChange(of: state.editAdapterID) { newValue in
            if newValue != nil { section = .harnesses }
        }
    }

    /// The detail pane. An in-progress harness edit takes the whole pane — the
    /// same Settings window, not a separate one — otherwise the sidebar's
    /// selected section. `Set` and `Cancel` clear the edit target, which returns
    /// the pane to the harness list.
    @ViewBuilder
    private var detail: some View {
        switch section ?? .general {
        case .general: generalDetail
        case .apiKey: apiKeyDetail
        case .menuBar: menuBarDetail
        case .harnesses:
            // The editor replaces the list inside the Agent Harnesses pane, so
            // the sidebar stays live and any other section can be selected while
            // editing; its changes are already saved.
            if let row = editingRow {
                // No outer ScrollView: the provider Table scrolls itself, and
                // two nested scrollers is what folded the old Grid over itself.
                ModelEditorView(state: state, row: row)
            } else {
                harnessesDetail
            }
        case .alerts: alertsDetail
        case .about: aboutDetail
        }
    }

    /// The harness currently being edited, if its row is known.
    private var editingRow: ToolRow? {
        guard let id = state.editAdapterID else { return nil }
        return state.rows.first { $0.id == id }
    }

    /// A settings row with a title and an optional secondary line, so the
    /// grouped card reads like the system ones rather than a bare toggle label.
    private func settingToggle(_ title: String, subtitle: String? = nil,
                               isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var apiKeyDetail: some View {
        Form {
            Section {
                Picker("Store key in", selection: Binding(
                    get: { state.config.keyStorage },
                    set: { state.setKeyStorage($0) })) {
                    Text("File (~/.pesa-app/settings.json)").tag(KeyStorage.file)
                    Text("Keychain").tag(KeyStorage.keychain)
                }
                // Full-width on its own line. A bare `SecureField` in a grouped
                // `Form` puts its label on the left and shares the row, pushing
                // the field narrow, so the label is hidden and the field stands
                // alone.
                // `overlay` draws on top without affecting the base view's size,
                // so the mask below cannot widen or over-stretch the field;
                // `clipped()` stops the dots at the field's edge. `maxWidth:
                // infinity` makes the field exactly the row (and so window) width.
                SecureField("OpenRouter API key", text: $state.apiKeyInput, prompt: Text(
                    state.hasKey ? "" : "Paste your OpenRouter API key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if state.hasKey && state.apiKeyInput.isEmpty {
                            Text(String(repeating: "•", count: 400))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                HStack {
                    Button("Save") { state.saveKey() }
                        .disabled(state.apiKeyInput.isEmpty)
                    Button("Test key") { Task { await state.testKey() } }
                    Button("Clear") { state.clearKey() }
                        .disabled(!state.hasKey)
                }
                Text(state.hasKey ? "A key is stored in \(state.keyStorageDescription)." : "No key stored yet.")
                    .foregroundStyle(.secondary)
                if let status = state.keyStatus {
                    Text(status).foregroundStyle(.secondary)
                }
            } header: {
                Text("OpenRouter API key")
            } footer: {
                switch state.config.keyStorage {
                case .file:
                    Text("The file is created owner-only (0600), but the key is plain text — keep ~/.pesa-app private.")
                case .keychain:
                    Text("macOS may ask once to allow Keychain access; choose Always Allow. A rebuild with an ad-hoc signature makes it ask again.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var generalDetail: some View {
        Form {
            Section("Balance") {
                TextField("Refresh every (minutes)", value: $state.config.refreshMinutes,
                          format: .number)
            }
            Section("Startup") {
                settingToggle("Launch at login",
                              subtitle: "Start Pesa when you log in.",
                              isOn: Binding(get: { state.config.launchAtLogin },
                                            set: { state.setLaunchAtLogin($0) }))
                if let error = state.launchAtLoginError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The harness registry. Detection still finds every installed harness; this
    /// section is where the user opts one into the popover and reaches its
    /// editor. `SettingsView.body` owns the one discovery pass that populates
    /// `rows`, so opening Settings first still lets a harness be added.
    private var harnessesDetail: some View {
        Form {
            Section {
                if !state.hasCompletedDiscovery {
                    Text("Checking agents…").foregroundStyle(.secondary)
                } else if state.rows.isEmpty {
                    Text("No harnesses detected.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.rows, id: \.id) { row in
                        harnessRow(row)
                    }
                }
            } header: {
                Text("Detected harnesses")
            } footer: {
                Text("Added harnesses appear in the popover. Configure… opens the model editor.")
            }
        }
        .formStyle(.grouped)
    }

    private func harnessRow(_ row: ToolRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                Text(formatHarnessModel(row.state))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = state.rowErrors[row.id] {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: addedBinding(for: row.id))
                .labelsHidden()
            // An unreadable harness has no model to edit, so it offers no
            // Configure button; its error above explains why.
            if state.rowErrors[row.id] == nil {
                Button("Configure…") {
                    state.beginEdit(row)
                }
            }
        }
    }

    /// Membership in `addedHarnesses`. The write goes through `config`'s
    /// `didSet`, which saves and re-runs discovery because
    /// `ConfigChange.affectsRows` fires on this field.
    private func addedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { state.config.addedHarnesses.contains(id) },
            set: { isOn in
                if isOn {
                    if !state.config.addedHarnesses.contains(id) {
                        state.config.addedHarnesses.append(id)
                    }
                } else {
                    state.config.addedHarnesses.removeAll { $0 == id }
                }
            })
    }

    private var menuBarDetail: some View {
        Form {
            Section("Menu bar") {
                settingToggle("Show balance", isOn: $state.config.showMoneyInMenuBar)
                settingToggle("Show icon", isOn: $state.config.showIconInMenuBar)
                settingToggle("Hide the price until hovered",
                              subtitle: "Replaces the amount with ...$ and reveals the real figure while the pointer is on the icon.",
                              isOn: $state.config.hidesAmountInMenuBar)
            }
            Section {
                Text("The icon stays visible if both are cleared, so the menu bar item remains clickable.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var alertsDetail: some View {
        Form {
            Section("Low balance") {
                settingToggle("Notify when the balance falls below",
                              isOn: Binding(get: { state.config.notifyBelowEnabled },
                                            set: { state.setAlertEnabled($0) }))
                TextField("Threshold ($)", value: $state.config.notifyBelowAmount,
                          format: .number)
            }
            Section {
                Text("Notification permission: \(state.authorizationStatusText)")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutDetail: some View {
        Form {
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Provider", value: "OpenRouter")
            }
            Section {
                Button("Buy credits…") {
                    if let url = URL(string: "https://openrouter.ai/settings/credits") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
