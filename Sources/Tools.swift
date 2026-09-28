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
}

// MARK: - pi

/// File existence is the primary signal: a Finder-launched app gets a minimal
/// `PATH`, so a `pi` binary lookup can miss even when pi is installed.
private func detectPi(_ paths: ToolPaths) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: paths.piSettings) { return true }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        if fm.isExecutableFile(atPath: "\(dir)/pi") { return true }
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
