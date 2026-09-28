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
