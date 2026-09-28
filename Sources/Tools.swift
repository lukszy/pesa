import Foundation

/// One coding agent's adapter surface. Every member is a closure supplied by a
/// `Tools.*` factory, so Tasks 5–7 can add adapters by building another value
/// without touching this shape. Task 8 adds `state()` as an extension.
struct ToolAdapter {
    let id: String
    let displayName: String
    let detect: () -> Bool
    let currentModel: () throws -> ToolModelRef?
    let providers: () throws -> [String]
    let models: (_ provider: String) throws -> [(id: String, name: String)]
    let setModel: (_ ref: ToolModelRef) throws -> Void
}

enum Tools {

    static func pi(_ paths: ToolPaths) -> ToolAdapter {
        ToolAdapter(
            id: "pi",
            displayName: "pi",
            detect: { detectPi(paths) },
            currentModel: { try currentPiModel(paths) },
            providers: { try piProviders(paths) },
            models: { provider in try piModels(paths, provider: provider) },
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
            detect: { detectHermes(paths) },
            currentModel: { try currentHermesModel(paths) },
            providers: { try hermesProviders(paths) },
            models: { provider in try hermesModels(paths, provider: provider) },
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
            detect: { detectOpencode(paths) },
            currentModel: { try currentOpencodeModel(paths) },
            providers: { try opencodeProviders(paths) },
            models: { provider in try opencodeModels(paths, provider: provider) },
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
/// model ids, so an unconfigured provider legitimately yields an empty list.
/// Task 11 injects the hosted catalog later.
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
/// model catalog (Task 11 injects the hosted one); the configured `model:`
/// scalar is the one local entry and belongs only to its own provider.
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
/// every adapter's detection. Callers put file existence first because a
/// Finder-launched app gets a minimal `PATH`, so this lookup alone can miss an
/// installed tool whose config exists.
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
