import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// What the menu bar status item renders. Pure, so the behaviour a user would
/// otherwise have to observe by eye is testable. `StatusItemController` renders
/// the result.
enum MenuBarPresentation {
    static func of(showMoney: Bool, showIcon: Bool, balance: Double?, error: Bool)
        -> (text: String?, symbol: String?) {
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
            // Unreadable config: show the problem and disable the action,
            // rather than hiding the tool or pretending it is unset.
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
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var rows: [ToolRow] = []
    /// True while an async discovery pass is in flight, so the popover can show
    /// a subdued placeholder instead of an empty box.
    @Published var isDiscovering = false

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
            CatalogCache.entries = catalog
        }

        guard let key = Keychain.get(account: Self.keychainAccount), !key.isEmpty else {
            errorText = "No OpenRouter API key. Add one in Settings."
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
            keyStatus = String(format: "Key works. Remaining $%.2f.", credits.remaining)
        } catch {
            keyStatus = "Key test failed: \(describe(error))"
        }
    }

    func importKeyFromPi() {
        guard let key = Keychain.importFromPi(paths) else {
            keyStatus = "No OpenRouter key found in pi's auth file."
            return
        }
        do {
            try Keychain.set(key, account: Self.keychainAccount)
            hasKey = true
            keyStatus = "Imported the key from pi."
        } catch {
            keyStatus = "Could not import the key: \(describe(error))"
        }
    }

    func clearKey() {
        do {
            try Keychain.delete(account: Self.keychainAccount)
            apiKeyInput = ""
            hasKey = false
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
        content.body = String(format: "Remaining $%.2f, below your $%.2f threshold.", balance, threshold)
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

    @State private var editingRowID: String?
    @State private var editProvider = ""
    @State private var editModel = ""
    @State private var editProviders: [String] = []
    @State private var editModels: [(id: String, name: String)] = []

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                // The popover always shows the balance, even when the menu bar
                // hides it. The status item's text comes from
                // MenuBarPresentation, not from this view.
                Text(balanceText).font(.title2).bold()
                if let updated = state.lastUpdated {
                    Text("Updated \(updated, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await state.refresh() } }
                Button {
                    SettingsWindow.open()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            if let error = state.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var balanceText: String {
        guard let remaining = state.remaining else { return "—" }
        return String(format: "$%.2f", remaining)
    }

    // MARK: Tools

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.rows.isEmpty {
                // Discovery is asynchronous; while it is in flight the popover
                // is already on screen and this keeps it from looking empty.
                Text(state.isDiscovering ? "Checking agents…" : "No supported tools detected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.rows, id: \.id) { row in
                toolRow(row)
            }
        }
    }

    private func toolRow(_ row: ToolRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayName).bold()
                Text(modelText(row)).foregroundStyle(.secondary)
                Spacer()
                if row.writable {
                    Button(editingRowID == row.id ? "Close" : "Change…") {
                        if editingRowID == row.id { editingRowID = nil } else { beginEdit(row) }
                    }
                } else {
                    Text("read-only").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.rowErrors[row.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if editingRowID == row.id {
                editor(row)
            }
        }
    }

    private func modelText(_ row: ToolRow) -> String {
        switch row.state {
        case .missing: return "— missing"
        case .unset: return "— unset"
        case .configured(let ref): return "— \(ref.provider)/\(ref.model)"
        }
    }

    private func editor(_ row: ToolRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Provider", selection: Binding(
                get: { editProvider },
                set: { newValue in
                    editProvider = newValue
                    loadModels(for: row.id, provider: newValue, reset: true)
                })) {
                ForEach(editProviders, id: \.self) { Text($0).tag($0) }
            }
            if !editModels.isEmpty {
                Picker("Model", selection: $editModel) {
                    ForEach(modelOptions, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            // The picker is a convenience; free text is always accepted.
            TextField("or type a model id", text: $editModel)
            HStack {
                Button("Set") { commitEdit(row) }
                    .disabled(editProvider.isEmpty || editModel.isEmpty)
                Button("Cancel") { editingRowID = nil }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    /// Keeps the current value selectable so the Picker never logs an invalid
    /// selection for a model that is not in the fetched list.
    private var modelOptions: [(id: String, name: String)] {
        guard !editModel.isEmpty, !editModels.contains(where: { $0.id == editModel }) else {
            return editModels
        }
        return [(id: editModel, name: editModel)] + editModels
    }

    private func beginEdit(_ row: ToolRow) {
        editingRowID = row.id
        let current: ToolModelRef?
        if case .configured(let ref) = row.state { current = ref } else { current = nil }
        editProviders = state.providers(forAdapterID: row.id, current: current?.provider)
        editProvider = current?.provider ?? editProviders.first ?? ""
        editModels = state.models(forAdapterID: row.id, provider: editProvider)
        editModel = current?.model ?? editModels.first?.id ?? ""
    }

    private func loadModels(for adapterID: String, provider: String, reset: Bool) {
        editModels = state.models(forAdapterID: adapterID, provider: provider)
        if reset || !editModels.contains(where: { $0.id == editModel }) {
            editModel = editModels.first?.id ?? ""
        }
    }

    private func commitEdit(_ row: ToolRow) {
        state.setModel(ToolModelRef(provider: editProvider, model: editModel), for: row.id)
        editingRowID = nil
    }

}

/// The settings content, shown in the SwiftUI `Settings` scene opened by the
/// popover's gear button and the app menu's Settings… item. Quit intentionally
/// lives on the status item's right-click menu now, not here.
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
        // The clawdbot override field renders from the detected rows, so make
        // sure they are populated even when Settings is opened from ⌘, before
        // the popover has ever triggered discovery. Async and coalesced, so a
        // popover that already discovered is not blocked.
        .task { await state.discoverProviders() }
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
                Button("Import from pi") { state.importKeyFromPi() }
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
    /// path and silently ignore it.
    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tool path overrides").font(.headline)
            Text("Point clawdbot at a non-standard binary location. The other tools read their config files directly, so they have no binary path to override.")
                .font(.caption).foregroundStyle(.secondary)
            if let row = state.rows.first(where: { $0.id == "clawdbot" }) {
                HStack {
                    Text(row.displayName).frame(width: 70, alignment: .leading)
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
}
