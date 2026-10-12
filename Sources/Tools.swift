import Foundation

/// One coding agent's adapter surface. Every member is a closure supplied by a
/// `Tools.*` factory, so an adapter is built by assembling another value
/// without touching this shape.
struct ToolAdapter {
    let id: String
    let displayName: String
    /// SF Symbol name for this harness. It travels on the adapter so the
    /// popover tile, the Settings row, and the harness window share one source
    /// instead of each mapping an id to a symbol.
    let symbol: String
    let detect: () -> Bool
    let currentModel: () throws -> ToolModelRef?
    let providers: () throws -> [String]
    /// `@MainActor` because the model list merges in `CatalogCache`, whose
    /// entries are main-actor state. Callers reach the catalog from `AppState`
    /// on the main actor; an off-main caller is a compile error, not a race.
    let models: @MainActor (_ provider: String) throws -> [(id: String, name: String)]
    let setModel: (_ ref: ToolModelRef) throws -> Void

    /// The row state the UI renders from. `.missing` when the tool is not
    /// installed, `.unset` when it is installed with no model configured, and
    /// `.configured` otherwise. A `currentModel()` error throws rather than
    /// folding into `.missing`, so an unreadable config is reported instead of
    /// hidden.
    func state() throws -> ToolState {
        guard detect() else { return .missing }
        guard let ref = try currentModel() else { return .unset }
        return .configured(ref)
    }
}

/// What a tool's config currently says, once detection has run.
enum ToolState: Equatable {
    case missing
    case unset
    case configured(ToolModelRef)
}

/// The OpenRouter model catalog, fetched once per refresh by `AppState.refresh`
/// and read synchronously by the adapters' `models` closures. Those closures
/// cannot `await`, so the async fetch lands here and they read it as plain
/// state. Empty until the first successful fetch; a failed fetch leaves it as
/// it was, so the picker falls back to each tool's own configured models.
@MainActor
enum CatalogCache {
    static var entries: [(id: String, name: String)] = []
    /// Base rates and context windows keyed by model id, from the same `/models`
    /// body as `entries`. Persisted in the catalog cache alongside the model
    /// list, so a fresh cache serves them with no fetch; they are refetched
    /// only when the cache is stale or was written before details existed.
    static var details: [String: ModelDetail] = [:]

    /// The one rule for replacing known prices with a fetch result: only a map
    /// carrying a real datum may replace them, so a body with no pricing (an
    /// empty map, or one whose every entry is the all-nil placeholder) cannot
    /// blank prices already shown. Pure, so the rule is testable offline.
    static func mergeDetails(existing: [String: ModelDetail],
                             new: [String: ModelDetail]) -> [String: ModelDetail] {
        Catalog.hasData(new) ? new : existing
    }

    /// OpenRouter's global catalog applies only to the `openrouter` provider;
    /// every other provider keeps the tool's own configured models. Catalog
    /// entries come first, then the tool's own, de-duplicated by id, so a
    /// non-empty cache never hides a locally configured model.
    static func withCatalog(_ models: [(id: String, name: String)], provider: String)
        -> [(id: String, name: String)] {
        guard provider == "openrouter", !entries.isEmpty else { return models }
        var result = entries
        var seen = Set(result.map { $0.id })
        for model in models where seen.insert(model.id).inserted {
            result.append(model)
        }
        return result
    }
}

enum Tools {

    /// Every adapter, in the order the UI presents them.
    static func all(_ paths: ToolPaths) -> [ToolAdapter] {
        [pi(paths), opencode(paths), hermes(paths)]
    }

    /// The registry's filter, split out from `all` so it is testable. pi and
    /// opencode each fall back to `PATH`, so for those a check relying on a
    /// staged tool being absent cannot fail on a machine where the tool is
    /// installed; hermes has no such fallback and is the absence case.
    static func detected(_ adapters: [ToolAdapter]) -> [ToolAdapter] {
        adapters.filter { $0.detect() }
    }

    /// Production entry point: only the installed tools, in `all`'s order.
    static func detected(_ paths: ToolPaths) -> [ToolAdapter] {
        detected(all(paths))
    }

    static func pi(_ paths: ToolPaths) -> ToolAdapter {
        ToolAdapter(
            id: "pi",
            displayName: "pi",
            symbol: "circle.hexagongrid",
            detect: { detectPi(paths) },
            currentModel: { try currentPiModel(paths) },
            providers: { try piProviders(paths) },
            models: { provider in CatalogCache.withCatalog(try piModels(paths, provider: provider), provider: provider) },
            setModel: { ref in
                // Two writes, not one. If the second fails the file pairs the new
                // provider with the old model; knowingly accepted (see plan), the
                // `.bak` holds the pre-write bytes for recovery.
                _ = try ConfigFile.setJSONString("defaultProvider", to: ref.provider, in: paths.piSettings)
                _ = try ConfigFile.setJSONString("defaultModel", to: ref.model, in: paths.piSettings)
            }
        )
    }

    static func hermes(_ paths: ToolPaths) -> ToolAdapter {
        ToolAdapter(
            id: "hermes",
            displayName: "hermes",
            symbol: "paperplane",
            detect: { detectHermes(paths) },
            currentModel: { try currentHermesModel(paths) },
            providers: { try hermesProviders(paths) },
            models: { provider in CatalogCache.withCatalog(try hermesModels(paths, provider: provider), provider: provider) },
            setModel: { ref in
                // Hermes has no CLI on this machine, so a top-level YAML scalar
                // edit is the only write path. One line, so no torn write.
                _ = try ConfigFile.setYAMLScalar("model", to: ref.qualified, in: paths.hermesConfig)
            }
        )
    }

    static func opencode(_ paths: ToolPaths) -> ToolAdapter {
        ToolAdapter(
            id: "opencode",
            displayName: "opencode",
            symbol: "chevron.left.forwardslash.chevron.right",
            detect: { detectOpencode(paths) },
            currentModel: { try currentOpencodeModel(paths) },
            providers: { try opencodeProviders(paths) },
            models: { provider in CatalogCache.withCatalog(try opencodeModels(paths, provider: provider), provider: provider) },
            setModel: { ref in
                // Single top-level write, unlike pi's two, so there is no
                // torn-write concern here.
                _ = try ConfigFile.setJSONString("model", to: ref.qualified, in: paths.opencodeConfig)
            }
        )
    }

}

// MARK: - opencode

private func detectOpencode(_ paths: ToolPaths) -> Bool {
    FileManager.default.fileExists(atPath: paths.opencodeConfig)
        || isExecutableOnPath("opencode")
}

/// opencode stores a single `provider/model` string. The model id itself keeps
/// its slashes, which is exactly why `ToolModelRef.parse` splits on the first
/// slash only.
private func currentOpencodeModel(_ paths: ToolPaths) throws -> ToolModelRef? {
    guard let config = try jsonObject(paths.opencodeConfig),
          let model = config["model"] as? String else { return nil }
    return ToolModelRef.parse(model)
}

/// The union of providers declared in the config's `provider` block and the
/// authenticated providers in the auth file.
private func opencodeProviders(_ paths: ToolPaths) throws -> [String] {
    var names = Set<String>()
    if let config = try jsonObject(paths.opencodeConfig),
       let providers = config["provider"] as? [String: Any] {
        names.formUnion(providers.keys)
    }
    if let auth = try jsonObject(paths.opencodeAuth) { names.formUnion(auth.keys) }
    return names.sorted()
}

/// The model ids already configured for the provider. opencode takes free-text
/// model ids, so an unconfigured provider legitimately yields an empty list; the
/// OpenRouter catalog is merged in by `CatalogCache` when it has been fetched.
private func opencodeModels(_ paths: ToolPaths, provider: String) throws -> [(id: String, name: String)] {
    guard let config = try jsonObject(paths.opencodeConfig),
          let providers = config["provider"] as? [String: Any],
          let entry = providers[provider] as? [String: Any],
          let models = entry["models"] as? [String: Any] else { return [] }
    return models.keys.sorted().map { id in
        let name = (models[id] as? [String: Any])?["name"] as? String ?? id
        return (id: id, name: name)
    }
}

// MARK: - hermes

/// File existence only: the design table gives hermes no PATH lookup, because
/// hermes has no CLI to resolve.
private func detectHermes(_ paths: ToolPaths) -> Bool {
    FileManager.default.fileExists(atPath: paths.hermesConfig)
}

/// Hermes stores its model as one top-level `model: provider/model` scalar,
/// absent on a fresh install — which is why `setYAMLScalar` must insert it.
private func currentHermesModel(_ paths: ToolPaths) throws -> ToolModelRef? {
    guard let raw = try yamlScalar("model", in: paths.hermesConfig) else { return nil }
    return ToolModelRef.parse(raw)
}

/// The curated known-provider list, unioned with the top-level `providers:`
/// keys in the config and the providers implied by `*_API_KEY` names in the
/// env file.
private func hermesProviders(_ paths: ToolPaths) throws -> [String] {
    var names: Set<String> = ["openrouter", "openai", "anthropic", "google", "nous", "zai", "kimi", "deepseek"]
    names.formUnion(try yamlMappingKeys("providers", in: paths.hermesConfig))

    if FileManager.default.fileExists(atPath: paths.hermesEnv) {
        for line in try ConfigFile.read(paths.hermesEnv).split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.hasPrefix("#"), let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            guard key.hasSuffix("_API_KEY") else { continue }
            names.insert(String(key.dropLast("_API_KEY".count)).lowercased())
        }
    }
    return names.sorted()
}

/// The model ids already configured for the provider. Hermes keeps no local
/// model catalog; the OpenRouter catalog is merged in by `CatalogCache` when it
/// has been fetched. The configured `model:` scalar is the one local entry and
/// belongs only to its own provider.
private func hermesModels(_ paths: ToolPaths, provider: String) throws -> [(id: String, name: String)] {
    guard let current = try currentHermesModel(paths), current.provider == provider else { return [] }
    return [(id: current.model, name: current.model)]
}

/// The value of a top-level YAML `key: value` scalar, or nil when absent. Only
/// the one scalar hermes stores a model in is read; nested YAML is never parsed.
private func yamlScalar(_ key: String, in path: String) throws -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let text = try ConfigFile.read(path)
    let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key))[ \\t]*:[ \\t]*(.*)$"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    let value = text[valueRange].trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
}

/// Immediate keys of a top-level YAML mapping, such as the provider names under
/// `providers:`. Only the first indentation level below the section header is
/// read; a provider's own nested block is never entered.
private func yamlMappingKeys(_ section: String, in path: String) throws -> Set<String> {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    let text = try ConfigFile.read(path)
    var keys = Set<String>()
    var sectionIndent: Int?
    var childIndent: Int?

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let raw = String(line)
        let entry = raw.trimmingCharacters(in: .whitespaces)
        if entry.isEmpty || entry.hasPrefix("#") { continue }
        let indent = raw.prefix { $0 == " " }.count

        guard let base = sectionIndent else {
            // Only a column-0 header is the top-level section. A `providers:`
            // nested under another top-level key must not be accepted, or its
            // child keys surface as provider names the config does not have.
            if indent == 0 && entry.hasPrefix("\(section):") { sectionIndent = indent }
            continue
        }
        if indent <= base { break }
        if childIndent == nil { childIndent = indent }
        guard indent == childIndent, let colon = entry.firstIndex(of: ":") else { continue }
        let key = String(entry[..<colon]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { keys.insert(key) }
    }
    return keys
}

// MARK: - pi

private func detectPi(_ paths: ToolPaths) -> Bool {
    FileManager.default.fileExists(atPath: paths.piSettings)
        || isExecutableOnPath("pi")
}

/// Whether `name` resolves to an executable on the current `PATH`. Shared by
/// `detectPi` and `detectOpencode`; `detectHermes` is file existence only.
/// Callers put file existence first
/// because a Finder-launched app gets a minimal `PATH`, so this lookup alone can
/// miss an installed tool whose config exists.
private func isExecutableOnPath(_ name: String) -> Bool {
    let fm = FileManager.default
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        if fm.isExecutableFile(atPath: "\(dir)/\(name)") { return true }
    }
    return false
}

private func currentPiModel(_ paths: ToolPaths) throws -> ToolModelRef? {
    guard let settings = try jsonObject(paths.piSettings) else { return nil }
    guard let provider = settings["defaultProvider"] as? String,
          let model = settings["defaultModel"] as? String else { return nil }
    return ToolModelRef(provider: provider, model: model)
}

private func piProviders(_ paths: ToolPaths) throws -> [String] {
    var names = Set<String>()
    if let auth = try jsonObject(paths.piAuth) { names.formUnion(auth.keys) }
    if let models = try jsonObject(paths.piModels),
       let providers = models["providers"] as? [String: Any] {
        names.formUnion(providers.keys)
    }
    if let store = try jsonObject(paths.piModelsStore) { names.formUnion(store.keys) }
    return names.sorted()
}

/// Cached catalog entries first (they carry display names), then the tool's own
/// configured models as a fallback, de-duplicated by id.
private func piModels(_ paths: ToolPaths, provider: String) throws -> [(id: String, name: String)] {
    var result: [(id: String, name: String)] = []
    var seen = Set<String>()

    if let store = try jsonObject(paths.piModelsStore),
       let entry = store[provider] as? [String: Any],
       let models = entry["models"] as? [[String: Any]] {
        for model in models {
            guard let id = model["id"] as? String, seen.insert(id).inserted else { continue }
            result.append((id: id, name: model["name"] as? String ?? id))
        }
    }

    if let configured = try jsonObject(paths.piModels),
       let providers = configured["providers"] as? [String: Any],
       let entry = providers[provider] as? [String: Any],
       let models = entry["models"] as? [[String: Any]] {
        for model in models {
            guard let id = model["id"] as? String, seen.insert(id).inserted else { continue }
            result.append((id: id, name: id))
        }
    }

    return result
}

/// Parses a JSON object, returning nil when the file is absent. A present but
/// unreadable or non-object file throws rather than being silently skipped.
private func jsonObject(_ path: String) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let text = try ConfigFile.read(path)
    do {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ConfigError.malformed(path, "top level is not an object")
        }
        return object
    } catch let error as ConfigError {
        throw error
    } catch {
        throw ConfigError.malformed(path, "\(error)")
    }
}

// MARK: - pi session ledger

/// The most recently modified pi session transcript under `directory`, or nil.
/// pi nests sessions one level per project cwd; only `.jsonl` files count.
func latestPiSessionFile(in directory: String) -> String? {
    let fm = FileManager.default
    guard let projects = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
    var newest: (path: String, mtime: Date)?
    for project in projects {
        let projectDir = "\(directory)/\(project)"
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { continue }
        for file in files where file.hasSuffix(".jsonl") {
            let path = "\(projectDir)/\(file)"
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime { newest = (path, mtime) }
        }
    }
    return newest?.path
}

/// The OpenRouter generation id of the newest assistant turn in a pi session
/// transcript, or nil when the newest turn is not an OpenRouter call (or there
/// is none). Pure, so the transcript scan is testable without a session file.
func lastPiGenerationID(in transcript: String) -> String? {
    for line in transcript.split(separator: "\n").reversed() {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant" else { continue }
        // The newest assistant turn decides: if it was not an OpenRouter call
        // there is no generation to resolve, and an older turn must not show.
        guard message["provider"] as? String == "openrouter",
              let id = message["responseId"] as? String, id.hasPrefix("gen-") else { return nil }
        return id
    }
    return nil
}

/// ponytail: the one config edit that parses and re-serializes instead of
/// byte-preserving. Shared by every `models.json` writer. The target of every
/// edit is a nested object/array the regex primitives cannot address, and
/// models.json is plain JSON with no comments, so the round-trip loses only
/// key order/formatting — never data. `edit` mutates the root and returns
/// false for a no-op, in which case the file is left byte-for-byte untouched
/// (not even reformatted). The pre-write bytes are backed up to `<path>.bak`;
/// a fresh file is written owner-only, because models.json can hold an apiKey.
private func editPiModelsJSON(at path: String, _ edit: (inout [String: Any]) -> Bool) throws {
    let exists = FileManager.default.fileExists(atPath: path)
    var root: [String: Any] = [:]
    if exists {
        let text = try ConfigFile.read(path)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ConfigError.malformed(path, "top level is not an object")
        }
        root = object
    }

    guard edit(&root) else { return }

    let data = try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let text = String(decoding: data, as: UTF8.self) + "\n"
    if exists {
        try ConfigFile.backup(path)
        try ConfigFile.atomicWrite(text, to: path)
    } else {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// Stores `value` under `key` in `object`, or removes the key when `value` is
/// empty, so an edit never leaves an empty container behind.
private func setOrPrune(_ object: inout [String: Any], _ key: String, _ value: [String: Any]) {
    if value.isEmpty { object.removeValue(forKey: key) } else { object[key] = value }
}

/// Sets (or clears) the OpenRouter provider allow-list for one model in pi's
/// `models.json`, at `providers.openrouter.modelOverrides.<model>.compat.
/// openRouterRouting.only`, so pi actually routes through those providers.
/// An empty list removes the key and prunes the containers it leaves empty; a
/// no-op leaves the file untouched.
func setPiProviderOnly(model: String, only: [String], in path: String) throws {
    try editPiModelsJSON(at: path) { root in
        var providers = root["providers"] as? [String: Any] ?? [:]
        var openrouter = providers["openrouter"] as? [String: Any] ?? [:]
        var overrides = openrouter["modelOverrides"] as? [String: Any] ?? [:]
        var entry = overrides[model] as? [String: Any] ?? [:]
        var compat = entry["compat"] as? [String: Any] ?? [:]
        var routing = compat["openRouterRouting"] as? [String: Any] ?? [:]

        if only.isEmpty {
            guard routing["only"] != nil else { return false }
            routing.removeValue(forKey: "only")
        } else {
            guard routing["only"] as? [String] != only else { return false }
            routing["only"] = only
        }

        // Rebuild bottom-up, pruning any container the edit leaves empty.
        setOrPrune(&compat, "openRouterRouting", routing)
        setOrPrune(&entry, "compat", compat)
        setOrPrune(&overrides, model, entry)
        setOrPrune(&openrouter, "modelOverrides", overrides)
        setOrPrune(&providers, "openrouter", openrouter)
        setOrPrune(&root, "providers", providers)
        return true
    }
}

/// One flag of the global OpenRouter routing policy. Each flag owns exactly
/// one key of pi's `provider` object and the value it writes when on; off
/// removes that key so OpenRouter's default applies. Keys a flag does not own
/// (the other flag, or a hand-set `sort`/`order`) are never touched.
enum OpenRouterPolicyFlag: CaseIterable {
    /// `zdr: true` — route only to zero-data-retention endpoints.
    case requireZDR
    /// `allow_fallbacks: false` — fail rather than try a non-allowed provider.
    case disallowFallbacks

    var key: String {
        switch self {
        case .requireZDR: return "zdr"
        case .disallowFallbacks: return "allow_fallbacks"
        }
    }

    var onValue: Bool {
        switch self {
        case .requireZDR: return true
        case .disallowFallbacks: return false
        }
    }
}

/// Sets (or clears) one global routing-policy flag in pi's `models.json`, at
/// `providers.openrouter.compat.openRouterRouting`, which pi deep-merges into
/// every OpenRouter model beneath any per-model `modelOverrides` entry. Only
/// the flag's own key is compared and written, so a toggle never deletes the
/// other flag when the user set it by hand; the object and its parents are
/// pruned only once empty. A no-op leaves the file untouched.
func setPiOpenRouterPolicy(_ flag: OpenRouterPolicyFlag, enabled: Bool, in path: String) throws {
    try editPiModelsJSON(at: path) { root in
        var providers = root["providers"] as? [String: Any] ?? [:]
        var openrouter = providers["openrouter"] as? [String: Any] ?? [:]
        var compat = openrouter["compat"] as? [String: Any] ?? [:]
        var routing = compat["openRouterRouting"] as? [String: Any] ?? [:]

        let want: Bool? = enabled ? flag.onValue : nil
        guard routing[flag.key] as? Bool != want else { return false }
        routing[flag.key] = want

        setOrPrune(&compat, "openRouterRouting", routing)
        setOrPrune(&openrouter, "compat", compat)
        setOrPrune(&providers, "openrouter", openrouter)
        setOrPrune(&root, "providers", providers)
        return true
    }
}

/// Launch-time reconcile of the stored policy into pi: writes every flag that
/// is on, so a write that failed or predates pi's install is retried, and
/// never removes a key, so a hand-set flag survives an app whose toggle is
/// off. With both flags off it touches nothing, not even a missing file.
func reconcilePiOpenRouterPolicy(requireZDR: Bool, disallowFallbacks: Bool, in path: String) throws {
    if requireZDR { try setPiOpenRouterPolicy(.requireZDR, enabled: true, in: path) }
    if disallowFallbacks { try setPiOpenRouterPolicy(.disallowFallbacks, enabled: true, in: path) }
}
