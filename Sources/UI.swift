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
            text = redacted ? "$••••" : formatBalance(balance)
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

/// Which config edits require rebuilding the tool rows. Only the fields that
/// feed a row — the hidden set and the clawdbot binary override — may rebuild:
/// `adapter.state()` can spawn a CLI, so rebuilding on an interval, threshold,
/// toggle, or launch-at-login edit freezes the UI per keystroke. Pure, so the
/// decision is testable without an `AppState` or a real tool install.
enum ConfigChange {
    static func affectsRows(from old: AppConfig, to new: AppConfig) -> Bool {
        old.hiddenTools != new.hiddenTools
            || old.binaryPathOverrides != new.binaryPathOverrides
    }
}

/// The UI projection of one detected adapter. `writable` is false when the
/// adapter cannot perform a write — clawdbot without a binary — or when its
/// config could not be read, in which case its Change control is disabled and
/// `AppState.rowErrors` carries the problem.
struct ToolRow {
    let id: String
    let displayName: String
    let state: ToolState
    let providers: [String]
    let writable: Bool
}

/// Which detected harnesses render as tiles. A harness whose discovery failed
/// is dropped from the grid entirely rather than shown as a broken row; its
/// count drives the popover's subdued footer so the failure is not silent.
/// Pure, so the visibility rule is pinned by checks instead of by eye.
/// `failed` is `AppState.rowErrors`, keyed by adapter id.
enum HarnessTiles {
    static func visible(rows: [ToolRow], failed: [String: String]) -> [ToolRow] {
        rows.filter { failed[$0.id] == nil }
    }

    /// Failures that correspond to a row — i.e. the tiles actually excluded.
    /// Counting `failed.count` would also include failures for hidden tools.
    static func failedCount(rows: [ToolRow], failed: [String: String]) -> Int {
        rows.count - visible(rows: rows, failed: failed).count
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
/// `detect()`, `state()`, `providers()` and `Tools.canWrite` touch only the
/// filesystem and the adapters' non-main-actor closures. `CatalogCache` and
/// `ToolAdapter.models` are `@MainActor` and are never reached from here, so
/// this can run in a detached task without annotation changes.
func discoverAdapters(_ adapters: [ToolAdapter], hiddenTools: [String],
                      paths: ToolPaths) -> DiscoveryOutcome {
    var providers: [String: [String]] = [:]
    for adapter in adapters where adapter.detect() {
        if let list = try? adapter.providers() {
            providers[adapter.id] = list
        }
    }

    var rows: [ToolRow] = []
    var errors: [String: String] = [:]
    for adapter in Tools.detected(adapters) where !hiddenTools.contains(adapter.id) {
        do {
            let toolState = try adapter.state()
            rows.append(ToolRow(
                id: adapter.id,
                displayName: adapter.displayName,
                state: toolState,
                providers: providers[adapter.id] ?? [],
                writable: Tools.canWrite(adapter, paths: paths)))
        } catch {
            // Unreadable config: keep the row so the failure can be counted,
            // but `HarnessTiles.visible` excludes it from the grid. The error
            // text itself is never rendered inline; only the footer count is.
            errors[adapter.id] = describeError(error)
            rows.append(ToolRow(
                id: adapter.id,
                displayName: adapter.displayName,
                state: .unset,
                providers: [],
                writable: false))
        }
    }
    return DiscoveryOutcome(providers: providers, rows: rows, errors: errors)
}

/// Human-readable error text. Never includes key material: no error from the
/// Keychain or the network carries the credential. Free function so the
/// off-main discovery path can use the same mapping as `AppState.describe`.
func describeError(_ error: Error) -> String {
    if let openRouter = error as? OpenRouterError {
        switch openRouter {
        case .badStatus(let status): return "OpenRouter returned HTTP \(status)."
        case .notJSON: return "OpenRouter sent a response this app could not read."
        case .missingField(let field): return "OpenRouter's response was missing \(field)."
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
    @Published var alertAuthorized = false
    @Published var authorizationStatusText = "Checking…"
    @Published var launchAtLoginError: String?
    @Published var toolErrorText: String?
    @Published var rowErrors: [String: String] = [:]

    private let paths: ToolPaths
    private var providerCache: [String: [String]] = [:]
    private var previousBalance: Double?
    private var refreshTimer: Timer?
    private var isRefreshing = false
    /// Set when a discovery request lands mid-pass, so the newer settings are
    /// picked up instead of being dropped as stale.
    private var discoveryPending = false

    init(paths: ToolPaths = .real) {
        self.paths = paths
        self.config = AppConfig.load()
        self.hasKey = Keychain.get(account: Self.keychainAccount) != nil
        startRefreshTimer()
        Task { await refreshAuthorizationStatus() }
    }

    // MARK: - Adapters

    /// The real paths with any configured binary override applied. Only
    /// clawdbot runs a binary; the file-based adapters read their configs.
    private var effectivePaths: ToolPaths {
        var paths = self.paths
        if let override = config.binaryPathOverrides["clawdbot"], !override.isEmpty {
            paths.clawdbotBin = override
        }
        return paths
    }

    private var orderedAdapters: [ToolAdapter] { Tools.all(effectivePaths) }

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

        guard let key = Keychain.get(account: Self.keychainAccount), !key.isEmpty else {
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
    /// filesystem work and clawdbot's CLI launches run in a detached task; only
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
            let hiddenTools = config.hiddenTools
            let paths = effectivePaths
            let outcome = await Task.detached(priority: .userInitiated) {
                discoverAdapters(adapters, hiddenTools: hiddenTools, paths: paths)
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

    /// Editor state for the separate harness window. It lives here rather than
    /// as `@State` in a view so the window can be retargeted to another harness
    /// without rebuilding its content view.
    @Published var editAdapterID: String?
    @Published var editProvider = ""
    @Published var editModel = ""
    @Published var editProviders: [String] = []
    @Published var editModels: [(id: String, name: String)] = []

    func beginEdit(_ row: ToolRow) {
        editAdapterID = row.id
        let current: ToolModelRef?
        if case .configured(let ref) = row.state { current = ref } else { current = nil }
        editProviders = providers(forAdapterID: row.id, current: current?.provider)
        editProvider = current?.provider ?? editProviders.first ?? ""
        editModels = models(forAdapterID: row.id, provider: editProvider)
        editModel = current?.model ?? editModels.first?.id ?? ""
    }

    func loadModels(for adapterID: String, provider: String, reset: Bool) {
        editModels = models(forAdapterID: adapterID, provider: provider)
        if reset || !editModels.contains(where: { $0.id == editModel }) {
            editModel = editModels.first?.id ?? ""
        }
    }

    func commitEdit() {
        guard let adapterID = editAdapterID else { return }
        setModel(ToolModelRef(provider: editProvider, model: editModel), for: adapterID)
        editAdapterID = nil
    }

    /// Cancel: drop the edit target without writing. Mirrors the old inline
    /// editor's Cancel, which cleared `editingRowID` and changed nothing.
    func cancelEdit() {
        editAdapterID = nil
    }

    // MARK: - API key

    func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyStatus = "Enter a key first."
            return
        }
        do {
            try Keychain.set(key, account: Self.keychainAccount)
            apiKeyInput = ""
            hasKey = true
            // The previous key's per-key figures belong to a key that is no
            // longer stored; clear them so the popover cannot attribute them
            // to the new key until its own fetch lands.
            keyUsage = nil
            keyStatus = "Key saved to the Keychain."
        } catch {
            keyStatus = "Could not save the key: \(describe(error))"
        }
    }

    func testKey() async {
        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (Keychain.get(account: Self.keychainAccount) ?? "") : typed
        guard !key.isEmpty else {
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
        do {
            try Keychain.delete(account: Self.keychainAccount)
            apiKeyInput = ""
            hasKey = false
            // `refresh()` returns early with no stored key, so without this the
            // removed key's usage line would stay on screen indefinitely.
            keyUsage = nil
            keyStatus = "Key removed."
        } catch {
            keyStatus = "Could not remove the key: \(describe(error))"
        }
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
    /// bundled app (running `.build/ProviderCostController` directly), so the
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
    /// the Keychain or the network carries the credential.
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
        .frame(maxHeight: 520)
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
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .padding(.vertical, 6)
            // The balance above is account-wide; this line is for the one API
            // key. The help text says so, because with more than one key the
            // two figures do not reconcile.
            if let usage = state.keyUsage {
                Text(usageLine(usage))
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Usage for this API key. The balance above is account-wide.")
                if let progress = usage.limitProgress {
                    ProgressView(value: progress.remaining, total: progress.total)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text(limitLabel(progress, reset: usage.limitReset))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let updated = state.lastUpdated {
                Text("Updated \(updated, style: .relative)")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    private func usageLine(_ usage: KeyUsage) -> String {
        // "This key" is visible, not just a tooltip: the whole point of the
        // line is that it must not be read as part of the account-wide balance.
        "This key: Today \(formatBalance(usage.usageDaily)) · Month \(formatBalance(usage.usageMonthly))"
    }

    private func limitLabel(_ progress: (remaining: Double, total: Double), reset: String?) -> String {
        var text = "\(formatBalance(progress.remaining)) of \(formatBalance(progress.total)) remaining"
        if let reset { text += " · resets \(reset)" }
        return text
    }

    // MARK: Tools

    private var toolList: some View {
        let visible = HarnessTiles.visible(rows: state.rows, failed: state.rowErrors)
        let failed = HarnessTiles.failedCount(rows: state.rows, failed: state.rowErrors)
        return VStack(alignment: .leading, spacing: 8) {
            if state.rows.isEmpty {
                // Discovery is asynchronous; while it is in flight — or before
                // the first pass has finished — the popover is already on
                // screen and this keeps it from looking empty. Gating on
                // `isDiscovering` alone would flash "No supported tools
                // detected." on the very first open, before main.swift has
                // started discovery.
                Text(state.isDiscovering || !state.hasCompletedDiscovery
                     ? "Checking agents…" : "No supported tools detected.")
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
            HarnessWindow.open(for: row, state: state)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName).font(.body).bold()
                Text(modelText(row)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelText(_ row: ToolRow) -> String {
        if case .configured(let ref) = row.state { return "\(ref.provider)/\(ref.model)" }
        return "unset"
    }

}

/// The model editor, hosted in `HarnessWindow` rather than in the popover.
/// Reads and writes `AppState`'s editor fields so the window can be retargeted
/// to another harness on each open without keeping any state of its own.
struct ModelEditorView: View {
    @ObservedObject var state: AppState
    let row: ToolRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayName).font(.headline)
                if !row.writable {
                    Text("read-only").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Provider", selection: Binding(
                get: { state.editProvider },
                set: { newValue in
                    state.editProvider = newValue
                    state.loadModels(for: row.id, provider: newValue, reset: true)
                })) {
                ForEach(state.editProviders, id: \.self) { Text($0).tag($0) }
            }
            if !state.editModels.isEmpty {
                Picker("Model", selection: $state.editModel) {
                    ForEach(modelOptions, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            // The picker is a convenience; free text is always accepted.
            TextField("or type a model id", text: $state.editModel)
            if let detail = state.modelDetail(for: state.editModel),
               let summary = formatModelDetail(detail) {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Base rates from OpenRouter's public model catalog. Tiered overrides above a prompt-token threshold are not shown.")
            }
            if !row.writable {
                Text("No writable CLI was found, so this harness cannot be changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") {
                    state.cancelEdit()
                    HarnessWindow.dismiss()
                }
                Spacer()
                Button("Set") { state.commitEdit() }
                    .disabled(!row.writable || state.editProvider.isEmpty || state.editModel.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
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

/// One lazily-created `NSWindow` for the harness editor. The SwiftUI `Settings`
/// scene cannot be reused here: `openWindow` is unreliable from a view hosted in
/// an `NSPopover` because the popover sits outside the SwiftUI scene graph. The
/// window is created once and retargeted on each open, so a second click raises
/// the existing window instead of opening another.
@MainActor
enum HarnessWindow {
    private static var window: NSWindow?

    static func open(for row: ToolRow, state: AppState) {
        let window = self.window ?? makeWindow()
        self.window = window
        // Fresh root view per open: the editor's bindings read AppState's
        // editor fields, which `beginEdit` has just retargeted.
        window.contentView = NSHostingView(rootView: ModelEditorView(state: state, row: row))
        window.title = "ProviderCostController — \(row.displayName)"
        // Proven fix: without activate + makeKey the window reports
        // `isKeyWindow = false` and opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        // Resizable so a taller editor is not clipped. The default is above the
        // floor so the editor's optional model-detail and read-only lines fit on
        // first open; this is the minimum the user can resize down to.
        window.contentMinSize = NSSize(width: 420, height: 240)
        window.center()
        return window
    }

    /// Dismisses the editor without writing. Used by the editor's Cancel; the
    /// window is kept alive (`isReleasedWhenClosed = false`) and retargeted on
    /// the next open.
    static func dismiss() {
        window?.close()
    }
}

/// The settings content, shown in the SwiftUI `Settings` scene opened by the
/// status item's right-click `Settings…` item and the app menu's Settings…
/// item. Quit intentionally lives on the status item's right-click menu now,
/// not here.
struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                apiKeySection
                Divider()
                refreshSection
                Divider()
                menuBarSection
                Divider()
                alertsSection
                Divider()
                launchAtLoginSection
                Divider()
                overridesSection
            }
            .padding(20)
        }
        .frame(width: 420)
        .frame(maxHeight: 560)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API key").font(.headline)
            HStack {
                SecureField("OpenRouter API key", text: $state.apiKeyInput)
                Button("Save") { state.saveKey() }
                    .disabled(state.apiKeyInput.isEmpty)
            }
            HStack {
                Button("Test key") { Task { await state.testKey() } }
                Button("Clear") { state.clearKey() }
                    .disabled(!state.hasKey)
            }
            Text(state.hasKey ? "A key is stored in the Keychain." : "No key stored yet.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = state.keyStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var refreshSection: some View {
        HStack {
            Text("Refresh every")
            TextField("", value: $state.config.refreshMinutes, format: .number)
                .frame(width: 50)
            Text("minutes")
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Menu bar").font(.headline)
            Toggle("Show balance", isOn: $state.config.showMoneyInMenuBar)
            Toggle("Show icon", isOn: $state.config.showIconInMenuBar)
            Toggle("Hide the amount behind dots until hovered", isOn: $state.config.hidesAmountInMenuBar)
            Text("The icon stays visible if both are cleared, so the menu bar item remains clickable.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alerts").font(.headline)
            Toggle("Notify when the balance falls below", isOn: Binding(
                get: { state.config.notifyBelowEnabled },
                set: { state.setAlertEnabled($0) }))
            HStack {
                Text("Threshold $")
                TextField("", value: $state.config.notifyBelowAmount, format: .number)
                    .frame(width: 70)
            }
            Text("Notification permission: \(state.authorizationStatusText)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(
                get: { state.config.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }))
            if let error = state.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Only clawdbot runs a binary; the other three adapters read their config
    /// files directly, so only clawdbot's override is honoured by
    /// `AppState.effectivePaths`. Rendering a field for the others would accept a
    /// path and silently ignore it. The field no longer depends on `state.rows`,
    /// so opening Settings never triggers discovery.
    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tool path overrides").font(.headline)
            Text("Point clawdbot at a non-standard binary location. The other tools read their config files directly, so they have no binary path to override.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("clawdbot").frame(width: 70, alignment: .leading)
                TextField("binary path", text: Binding(
                    get: { state.config.binaryPathOverrides["clawdbot"] ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            state.config.binaryPathOverrides.removeValue(forKey: "clawdbot")
                        } else {
                            state.config.binaryPathOverrides["clawdbot"] = newValue
                        }
                    }))
            }
        }
    }
}
