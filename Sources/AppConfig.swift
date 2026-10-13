import Foundation

/// Persisted user settings, **including the OpenRouter API key**. The key is
/// stored in this plain JSON file (`~/.pesa-app/settings.json`) rather than the
/// Keychain, so the file and its directory are written owner-only (0600/0700).
/// Every field decodes with `decodeIfPresent(…) ?? default` rather than the
/// synthesised `init(from:)`, because the synthesised one throws on a missing
/// key: an older settings file would fail to decode as a whole, `load` would
/// fall back to defaults, and every setting the file did contain would be
/// silently reset. This app owns this file and its schema is growing, so that
/// upgrade wipe is a real scenario, not a hypothetical.
/// Where the OpenRouter key is stored. `file` is the default (plain
/// `~/.pesa-app/settings.json`); `keychain` is the opt-in macOS Keychain.
enum KeyStorage: String, Codable {
    case file
    case keychain
}

struct AppConfig: Codable {
    var refreshMinutes: Int = 10
    var launchAtLogin: Bool = false
    var addedHarnesses: [String] = []
    var providerOnly: [String: [String]] = [:]
    /// Global OpenRouter routing policy, written to pi for every OpenRouter
    /// model (`provider.zdr` / `provider.allow_fallbacks`). Off means the key
    /// is absent from the request, so OpenRouter's defaults apply.
    var requireZDR: Bool = false
    var disallowFallbacks: Bool = false
    /// `provider.data_collection = "deny"` and `provider.require_parameters`.
    var denyDataCollection: Bool = false
    var requireParameters: Bool = false
    /// `provider.sort`; nil leaves OpenRouter's default (load-balanced by price).
    var routingSort: String?
    /// `provider.quantizations` allow-list; empty means any quantization.
    var allowedQuantizations: [String] = []
    /// `provider.max_price` per million tokens, USD; nil means no limit.
    var maxPricePrompt: Double?
    var maxPriceCompletion: Double?
    var showMoneyInMenuBar: Bool = true
    var showIconInMenuBar: Bool = true
    var hidesAmountInMenuBar: Bool = false
    var notifyBelowEnabled: Bool = false
    var notifyBelowAmount: Double = 5.0
    /// Where the key lives. Defaults to the file; the Keychain is opt-in.
    var keyStorage: KeyStorage = .file
    /// The OpenRouter API key, when `keyStorage == .file`. `nil` means none is
    /// stored here. This file is hand-editable (the point of the file default).
    var apiKey: String?

    /// `~/.pesa-app`. A real user path; `load(from:)`/`save(to:)` take a path so
    /// the selftest can stay entirely inside a temp directory.
    static let directory: String = "\(NSHomeDirectory())/.pesa-app"
    static let path: String = "\(directory)/settings.json"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` around each field: a present-but-mistyped value ({"refreshMinutes": "10"})
        // throws from decodeIfPresent and must cost only its own field, not the struct.
        refreshMinutes = (try? c.decodeIfPresent(Int.self, forKey: .refreshMinutes)) ?? 10
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        addedHarnesses = (try? c.decodeIfPresent([String].self, forKey: .addedHarnesses)) ?? []
        providerOnly = (try? c.decodeIfPresent([String: [String]].self, forKey: .providerOnly)) ?? [:]
        requireZDR = (try? c.decodeIfPresent(Bool.self, forKey: .requireZDR)) ?? false
        disallowFallbacks = (try? c.decodeIfPresent(Bool.self, forKey: .disallowFallbacks)) ?? false
        denyDataCollection = (try? c.decodeIfPresent(Bool.self, forKey: .denyDataCollection)) ?? false
        requireParameters = (try? c.decodeIfPresent(Bool.self, forKey: .requireParameters)) ?? false
        routingSort = (try? c.decodeIfPresent(String.self, forKey: .routingSort)) ?? nil
        allowedQuantizations = (try? c.decodeIfPresent([String].self, forKey: .allowedQuantizations)) ?? []
        maxPricePrompt = (try? c.decodeIfPresent(Double.self, forKey: .maxPricePrompt)) ?? nil
        maxPriceCompletion = (try? c.decodeIfPresent(Double.self, forKey: .maxPriceCompletion)) ?? nil
        showMoneyInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showMoneyInMenuBar)) ?? true
        showIconInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showIconInMenuBar)) ?? true
        hidesAmountInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .hidesAmountInMenuBar)) ?? false
        notifyBelowEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notifyBelowEnabled)) ?? false
        notifyBelowAmount = (try? c.decodeIfPresent(Double.self, forKey: .notifyBelowAmount)) ?? 5.0
        keyStorage = (try? c.decodeIfPresent(KeyStorage.self, forKey: .keyStorage)) ?? .file
        // `String?` from `decodeIfPresent` is itself optional under `try?`, so it
        // is flattened explicitly rather than assigned as `String??`.
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? nil
    }

    func isOn(_ flag: OpenRouterPolicyFlag) -> Bool {
        switch flag {
        case .requireZDR: return requireZDR
        case .disallowFallbacks: return disallowFallbacks
        case .denyDataCollection: return denyDataCollection
        case .requireParameters: return requireParameters
        }
    }

    mutating func set(_ flag: OpenRouterPolicyFlag, _ on: Bool) {
        switch flag {
        case .requireZDR: requireZDR = on
        case .disallowFallbacks: disallowFallbacks = on
        case .denyDataCollection: denyDataCollection = on
        case .requireParameters: requireParameters = on
        }
    }

    /// Never throws: a missing or undecodable file is the defaults.
    static func load(from path: String = AppConfig.path) -> AppConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    func save(to path: String = AppConfig.path) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            // Owner-only, and re-applied every save because `createDirectory`
            // does not change the mode of an existing directory.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
        // The file holds the API key in plain text, so keep it owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// The single "a key is present" rule: a stored value only counts when it is
/// non-nil **and** non-empty. Pure, so it is checked offline against literals.
func isUsableAPIKey(_ key: String?) -> Bool {
    guard let key else { return false }
    return !key.isEmpty
}
