import Foundation

/// One coding agent's adapter surface. Every member is a closure supplied by a
/// `Tools.*` factory, so Tasks 5–7 can add adapters by building another value
/// without touching this shape.
struct ToolAdapter {
    let id: String
    let displayName: String
    let detect: () -> Bool
    let currentModel: () throws -> ToolModelRef?
    let providers: () throws -> [String]
    let models: (_ provider: String) throws -> [(id: String, name: String)]
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

enum Tools {

    /// Every adapter, in the order the UI presents them.
    static func all(_ paths: ToolPaths) -> [ToolAdapter] {
        [pi(paths), opencode(paths), hermes(paths), clawdbot(paths)]
    }

    /// The registry's filter, split out from `all` so it is testable with
    /// synthetic adapters: every real adapter's `detect()` falls back to `PATH`,
    /// so a check relying on a staged tool being absent cannot fail on a machine
    /// where that tool is installed.
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

    static func clawdbot(_ paths: ToolPaths, candidates: [String]? = nil) -> ToolAdapter {
        // Resolve once, at construction. Every invocation routes through this
        // absolute path: a Finder-launched app gets a minimal PATH, so a bare
        // `clawdbot` launch would fail confusingly instead of degrading to a
        // read-only row. An injected list replaces the real search list so the
        // no-binary file-parse fallback is reachable from a check.
        let binary = resolveClawdbotBinary(
            candidates: candidates ?? clawdbotBinaryCandidates(paths))
        return ToolAdapter(
            id: "clawdbot",
            displayName: "clawdbot",
            detect: { detectClawdbot(paths, binary: binary) },
            currentModel: { try currentClawdbotModel(paths, binary: binary) },
            providers: { try clawdbotProviders(binary: binary) },
            models: { provider in try clawdbotModels(binary: binary, provider: provider) },
            setModel: { ref in
                // clawdbot.json is JSON5, so the CLI's own `models set` is the
                // only safe write path. Back up the pre-write bytes first; the
                // adapter must never parse and re-serialize the file itself.
                guard let binary else {
                    throw ConfigError.write(paths.clawdbotConfig,
                                            "clawdbot binary not found; row is read-only")
                }
                _ = try ConfigFile.backup(paths.clawdbotConfig)
                let result = try runClawdbot(binary, ["models", "set", ref.qualified])
                guard result.status == 0 else {
                    throw ConfigError.write(paths.clawdbotConfig,
                                            "clawdbot models set exited \(result.status)")
                }
            }
        )
    }

    /// The first executable entry of `candidates`, otherwise nil. Pure, so the
    /// Finder-launch resolution is testable without launching anything.
    static func resolveClawdbotBinary(candidates: [String]) -> String? {
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Turns `clawdbot config get agents.defaults.model` stdout into a ref. The
    /// CLI emits the object form for an object config, the bare `provider/model`
    /// scalar for a string config, and a human-readable "not found" message (or
    /// nothing) when the key is unset. Anything unparseable is `nil`, not a
    /// throw — reading a config must not fail on the CLI's prose.
    static func parseClawdbotModel(_ stdout: String) -> ToolModelRef? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) {
            // The CLI emits the object form for an object config. An object
            // without a usable `primary` is unset: falling through to the scalar
            // branch would build a ref out of JSON punctuation such as
            // `{"fallbacks": ["openai`. A parsed object never falls through.
            guard let object = raw as? [String: Any],
                  let primary = object["primary"] as? String else { return nil }
            return ToolModelRef.parse(primary)
        }
        return ToolModelRef.parse(trimmed)
    }
}

// MARK: - clawdbot

/// The adapter's real search list: the injected `paths.clawdbotBin` first, then
/// standard install locations, then the process PATH as a last resort. A
/// Finder-launched app has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so the absolute
/// entries are what make the CLI findable in the shipped app.
private func clawdbotBinaryCandidates(_ paths: ToolPaths) -> [String] {
    var candidates = [
        paths.clawdbotBin,
        "/usr/local/bin/clawdbot",
        "/opt/homebrew/bin/clawdbot",
        "\(NSHomeDirectory())/.local/bin/clawdbot",
    ]
    candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map { "\($0)/clawdbot" }
    return candidates
}

/// The state directory is the primary signal, matching the other adapters'
/// file-first detection; the resolved binary is the fallback. Using the resolved
/// path — not a PATH-only lookup — makes detection agree with what the adapter
/// can actually run, including from a Finder launch.
private func detectClawdbot(_ paths: ToolPaths, binary: String?) -> Bool {
    FileManager.default.fileExists(atPath: paths.clawdbotDir) || binary != nil
}

/// Reads `agents.defaults.model`. The CLI is the authoritative reader because
/// `clawdbot.json` is JSON5: `JSONSerialization` throws on a commented file, so
/// a direct file parse must never be what the user sees. The file parse is a
/// fallback only for when the binary is unresolvable, where a comment-free
/// config still reads; if it also fails, the error surfaces rather than hides.
private func currentClawdbotModel(_ paths: ToolPaths, binary: String?) throws -> ToolModelRef? {
    if let binary {
        let result = try runClawdbot(binary, ["config", "get", "agents.defaults.model"])
        return Tools.parseClawdbotModel(result.stdout)
    }
    guard let config = try jsonObject(paths.clawdbotConfig),
          let agents = config["agents"] as? [String: Any],
          let defaults = agents["defaults"] as? [String: Any],
          let model = defaults["model"] else { return nil }
    if let raw = model as? String { return ToolModelRef.parse(raw) }
    if let object = model as? [String: Any], let primary = object["primary"] as? String {
        return ToolModelRef.parse(primary)
    }
    return nil
}

/// The provider names implied by the CLI's model keys, so the dropdown only
/// offers providers clawdbot actually has configured.
private func clawdbotProviders(binary: String?) throws -> [String] {
    var providers = Set<String>()
    for entry in try clawdbotModelEntries(binary: binary) {
        guard let key = entry["key"] as? String,
              let ref = ToolModelRef.parse(key) else { continue }
        providers.insert(ref.provider)
    }
    return providers.sorted()
}

private func clawdbotModels(binary: String?, provider: String) throws -> [(id: String, name: String)] {
    try clawdbotModelEntries(binary: binary).compactMap { entry in
        guard let key = entry["key"] as? String,
              ToolModelRef.parse(key)?.provider == provider else { return nil }
        return (id: key, name: entry["name"] as? String ?? key)
    }
}

/// Runs `clawdbot models list --json` and returns the parsed entries. stdout
/// only: the real CLI writes certificate warnings to stderr, and a noisy stderr
/// must not fail a read. A missing binary yields no entries rather than a crash.
private func clawdbotModelEntries(binary: String?) throws -> [[String: Any]] {
    guard let binary else { return [] }
    let result = try runClawdbot(binary, ["models", "list", "--json"])
    guard let data = result.stdout.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let object = raw as? [String: Any],
          let models = object["models"] as? [[String: Any]] else { return [] }
    return models
}

/// Launches the resolved clawdbot binary. stderr goes to the null device so a
/// warning cannot fill a pipe or fail a read. Throws only when the binary
/// cannot be launched at all; a non-zero exit is returned to the caller.
private func runClawdbot(_ binary: String, _ arguments: [String]) throws -> (stdout: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw ConfigError.write(binary, "could not launch clawdbot: \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
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
