import Foundation

/// Persisted user settings. Every field decodes with `decodeIfPresent(…) ??
/// default` rather than the synthesised `init(from:)`, because the synthesised
/// one throws on a missing key: an older settings file would fail to decode as
/// a whole, `load` would fall back to defaults, and every setting the file did
/// contain would be silently reset. This app owns this file and its schema is
/// growing, so that upgrade wipe is a real scenario, not a hypothetical.
struct AppConfig: Codable {
    var refreshMinutes: Int = 10
    var launchAtLogin: Bool = false
    var hiddenTools: [String] = []
    var binaryPathOverrides: [String: String] = [:]
    var showMoneyInMenuBar: Bool = true
    var showIconInMenuBar: Bool = true
    var hidesAmountInMenuBar: Bool = false
    var notifyBelowEnabled: Bool = false
    var notifyBelowAmount: Double = 5.0

    /// A real user path. `load(from:)`/`save(to:)` take a path so the selftest
    /// can stay entirely inside a temp directory.
    static let path: String = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("ProviderCostController/config.json").path
    }()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` around each field: a present-but-mistyped value ({"refreshMinutes": "10"})
        // throws from decodeIfPresent and must cost only its own field, not the struct.
        refreshMinutes = (try? c.decodeIfPresent(Int.self, forKey: .refreshMinutes)) ?? 10
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        hiddenTools = (try? c.decodeIfPresent([String].self, forKey: .hiddenTools)) ?? []
        binaryPathOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .binaryPathOverrides)) ?? [:]
        showMoneyInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showMoneyInMenuBar)) ?? true
        showIconInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showIconInMenuBar)) ?? true
        hidesAmountInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .hidesAmountInMenuBar)) ?? false
        notifyBelowEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notifyBelowEnabled)) ?? false
        notifyBelowAmount = (try? c.decodeIfPresent(Double.self, forKey: .notifyBelowAmount)) ?? 5.0
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
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
