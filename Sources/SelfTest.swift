import Foundation

enum SelfTest {
    private static var results: [(name: String, condition: Bool)] = []

    /// The single failure-accounting path, shared by `check` bookkeeping and
    /// `run`'s exit status. Its own coverage is the canary below.
    static func countFailures(_ checks: [(name: String, condition: Bool)]) -> Int {
        checks.reduce(0) { $0 + ($1.condition ? 0 : 1) }
    }

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        let passed = condition()
        results.append((name, passed))
        print(passed ? "PASS \(name)" : "FAIL \(name)")
    }

    static func run() -> Int32 {
        results = []
        // Durable, non-vacuous canary: fails if countFailures regresses.
        check("harness counts a failing check",
              countFailures([("deliberate false", false), ("deliberate true", true)]) == 1)
        checkStaging()
        checkConfigEdits()
        checkPiAdapter()
        checkOpencodeAdapter()
        checkHermesAdapter()
        checkClawdbotAdapter()
        checkRegistry()
        checkKeychain()
        checkOpenRouter()
        checkSettings()
        let anyFailed = results.contains { !$0.condition }
        return countFailures(results) == 0 && !anyFailed ? 0 : 1
    }

    /// Exercises the byte-preserving edit primitives against a staged temp copy
    /// of Tests/fixtures. Never touches a real user path.
    private static func checkConfigEdits() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")

            check("parse splits on the first slash only",
                ToolModelRef.parse("openrouter/anthropic/claude-fable-latest")?.model == "anthropic/claude-fable-latest")
            check("parse keeps a colon inside the model",
                ToolModelRef.parse("ollama/qwen3.8:latest")?.model == "qwen3.8:latest")
            check("parse rejects a string without a slash",
                ToolModelRef.parse("no-slash-here") == nil)

            let before = try ConfigFile.read(cfg.opencodeConfig)
            _ = try ConfigFile.setJSONString("model", to: "openrouter/acme/opus-1", in: cfg.opencodeConfig)
            let after = try ConfigFile.read(cfg.opencodeConfig)
            check("only the model value changed", after.replacingOccurrences(of: "openrouter/acme/opus-1", with: "omlx/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit") == before)
            let backupBytes = try ConfigFile.read(cfg.opencodeConfig + ".bak")
            check("backup holds the pre-write bytes", backupBytes == before)
            check("missing file is reported, not crashed", (try? ConfigFile.setJSONString("model", to: "x", in: "/nonexistent/y.json")) == nil)

            // A fresh install may have no top-level key at all. Writing must insert it, not silently no-op.
            let scratch = (cfg.piSettings as NSString).deletingLastPathComponent + "/no-model-key.json"
            try "{\n  \"theme\": \"dark\"\n}\n".write(toFile: scratch, atomically: true, encoding: .utf8)
            _ = try ConfigFile.setJSONString("model", to: "openrouter/acme/opus-1", in: scratch)
            let inserted = try ConfigFile.read(scratch)
            check("an absent JSON key is inserted, not ignored",
                inserted.contains("\"model\": \"openrouter/acme/opus-1\""))
            check("inserting the key kept the existing keys",
                inserted.contains("\"theme\": \"dark\""))

            // The key must be matched at the document's top-level indent, so a nested key of the same name survives.
            let nested = (cfg.piSettings as NSString).deletingLastPathComponent + "/nested-model.json"
            try "{\n  \"model\": \"top/one\",\n  \"provider\": {\n    \"omlx\": {\n      \"model\": \"nested/two\"\n    }\n  }\n}\n"
                .write(toFile: nested, atomically: true, encoding: .utf8)
            _ = try ConfigFile.setJSONString("model", to: "top/three", in: nested)
            let nestedAfter = try ConfigFile.read(nested)
            check("the top-level key took the new value", nestedAfter.contains("\"model\": \"top/three\""))
            check("the nested model key is untouched", nestedAfter.contains("\"model\": \"nested/two\""))

            // Minified JSON has no line-start key to key off. It must fail as
            // malformed rather than be rewritten with a duplicate key.
            let minified = (cfg.piSettings as NSString).deletingLastPathComponent + "/minified.json"
            let minifiedBytes = "{\"model\":\"x\"}"
            try minifiedBytes.write(toFile: minified, atomically: true, encoding: .utf8)
            check("a minified JSON document is rejected, not duplicated",
                (try? ConfigFile.setJSONString("model", to: "a/b", in: minified)) == nil)
            let minifiedAfter = try ConfigFile.read(minified)
            check("a rejected minified write left the file byte-identical", minifiedAfter == minifiedBytes)

            // An empty object has no keys to duplicate and must still insert.
            let emptyObject = (cfg.piSettings as NSString).deletingLastPathComponent + "/empty.json"
            try "{}".write(toFile: emptyObject, atomically: true, encoding: .utf8)
            let emptyResult = try? ConfigFile.setJSONString("model", to: "a/b", in: emptyObject)
            let emptyAfter = try ConfigFile.read(emptyObject)
            check("an empty JSON object still takes the insert path",
                emptyResult != nil && emptyAfter.contains("\"model\": \"a/b\""))

            // The hermes fixture has no top-level model: line, so this is the live
            // absent-key insertion path for YAML.
            _ = try ConfigFile.setYAMLScalar("model", to: "openrouter/deepseek/deepseek-v4.1-flash", in: cfg.hermesConfig)
            let hermesAfter = try ConfigFile.read(cfg.hermesConfig)
            check("an absent YAML key is appended, not ignored",
                hermesAfter.contains("model: openrouter/deepseek/deepseek-v4.1-flash"))
            check("appending the YAML key kept the existing keys",
                hermesAfter.contains("orca-status"))

            // An existing YAML key is replaced in place rather than duplicated.
            let yaml = (cfg.piSettings as NSString).deletingLastPathComponent + "/has-model.yaml"
            try "model: old/model\nplugins:\n  - keep\n".write(toFile: yaml, atomically: true, encoding: .utf8)
            _ = try ConfigFile.setYAMLScalar("model", to: "new/model", in: yaml)
            let yamlAfter = try ConfigFile.read(yaml)
            check("an existing YAML key is replaced, not duplicated",
                yamlAfter.contains("model: new/model") && !yamlAfter.contains("old/model"))
            check("replacing the YAML key kept the existing keys", yamlAfter.contains("- keep"))

            // rename replaces the inode; a write must not loosen a config whose
            // API keys were protected by a restrictive mode.
            let secret = (cfg.piSettings as NSString).deletingLastPathComponent + "/secret.json"
            try "{\n  \"apiKey\": \"not-a-real-key\"\n}\n".write(toFile: secret, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret)
            _ = try ConfigFile.setJSONString("model", to: "openrouter/acme/opus-1", in: secret)
            let mode = (try FileManager.default.attributesOfItem(atPath: secret)[.posixPermissions] as? NSNumber)?.intValue
            check("a write preserves the config's restrictive mode", mode == 0o600)
        } catch {
            check("config edit checks could not run: \(error)", false)
        }
    }

    /// Exercises the pi adapter against a staged temp copy of Tests/fixtures.
    /// Never touches a real user path. Throwing calls are hoisted out of
    /// `check`'s non-throwing autoclosure exactly as the Task 3 checks do.
    private static func checkPiAdapter() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")
            let pi = Tools.pi(cfg)

            check("pi detects", pi.detect())

            let initial = try pi.currentModel()
            check("pi reads current model",
                  initial == ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash"))

            let providers = try pi.providers()
            check("pi providers include authed and configured ones",
                  Set(providers).isSuperset(of: ["openrouter", "openai", "ollama"]))

            let openrouterModels = try pi.models("openrouter")
            check("pi model list carries display names",
                  openrouterModels.contains { $0.id == "~anthropic/claude-fable-latest" })

            let ollamaModels = try pi.models("ollama")
            check("pi model list falls back to configured models",
                  ollamaModels.contains { $0.id == "qwen3.8:latest" })

            try pi.setModel(ToolModelRef(provider: "openai", model: "gpt-5.6-luna"))
            let written = try pi.currentModel()
            check("pi wrote both keys",
                  written == ToolModelRef(provider: "openai", model: "gpt-5.6-luna"))
            let settingsAfter = try ConfigFile.read(cfg.piSettings)
            check("pi preserved the rest of settings.json",
                  settingsAfter.contains("\"defaultThinkingLevel\""))

            // Read-only config. `rename(2)` only needs write permission on the
            // parent directory, so chmodding the file alone would let the write
            // succeed for the wrong reason: stage the file in its own subdir and
            // make that 0555, then restore 0755.
            let readonlyDir = (cfg.piSettings as NSString).deletingLastPathComponent
                + "/readonly-\(UUID().uuidString)"
            let fm = FileManager.default
            try fm.createDirectory(atPath: readonlyDir, withIntermediateDirectories: true)
            let readonlyFile = readonlyDir + "/pi-settings.json"
            try fm.copyItem(atPath: cfg.piSettings, toPath: readonlyFile)
            var readonlyCfg = cfg
            readonlyCfg.piSettings = readonlyFile
            let readonlyPi = Tools.pi(readonlyCfg)
            let readonlyBefore = try ConfigFile.read(readonlyFile)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonlyDir)
            check("read-only config reports an error",
                  (try? readonlyPi.setModel(ToolModelRef(provider: "x", model: "y"))) == nil)
            let readonlyAfter = try ConfigFile.read(readonlyFile)
            check("read-only config is left byte-identical", readonlyAfter == readonlyBefore)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonlyDir)
        } catch {
            check("pi adapter checks could not run: \(error)", false)
        }
    }

    /// Exercises the opencode adapter against a staged temp copy of
    /// Tests/fixtures. Never touches a real user path.
    private static func checkOpencodeAdapter() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")
            let oc = Tools.opencode(cfg)

            check("opencode detects", oc.detect())

            let initial = try oc.currentModel()
            check("opencode reads the nested model id",
                  initial == ToolModelRef(provider: "omlx",
                      model: "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"))

            let providers = try oc.providers()
            check("opencode providers union config and auth",
                  Set(providers).isSuperset(of: ["omlx", "lmstudio", "openrouter"]))

            let omlxModels = try oc.models("omlx")
            check("opencode lists the configured omlx model",
                  omlxModels.contains { $0.id == "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit" })
            let unconfigured = try oc.models("openrouter")
            check("opencode returns no models for an unconfigured provider",
                  unconfigured.isEmpty)

            try oc.setModel(ToolModelRef(provider: "openrouter", model: "acme/opus-1"))
            let written = try oc.currentModel()
            check("opencode wrote the model",
                  written == ToolModelRef(provider: "openrouter", model: "acme/opus-1"))
            let configAfter = try ConfigFile.read(cfg.opencodeConfig)
            check("opencode preserved its provider block",
                  configAfter.contains("@ai-sdk/openai-compatible"))
        } catch {
            check("opencode adapter checks could not run: \(error)", false)
        }
    }

    /// Exercises the hermes adapter against a staged temp copy of
    /// Tests/fixtures. Never touches a real user path. Throwing calls are
    /// hoisted out of `check`'s non-throwing autoclosure.
    private static func checkHermesAdapter() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")
            let he = Tools.hermes(cfg)

            check("hermes detects from config.yaml", he.detect())

            let unset = try he.currentModel()
            check("hermes reports no model when unset", unset == nil)

            try he.setModel(ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash"))
            let written = try he.currentModel()
            check("hermes wrote a top-level model",
                  written == ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash"))
            let configAfter = try ConfigFile.read(cfg.hermesConfig)
            check("hermes kept the plugins block", configAfter.contains("orca-status"))

            let providers = try he.providers()
            // `synthetic` is neither curated nor in the fixture YAML, so this
            // fails if the `*_API_KEY` parsing is removed. `openrouter` alone
            // would not: it is already in the curated list.
            check("hermes providers include env-configured ones",
                  Set(providers).isSuperset(of: ["openrouter", "synthetic"]))

            // A nested providers: section must not be read as the top-level one:
            // only a column-0 header is the section this adapter reads.
            let nestedPath = (cfg.piSettings as NSString).deletingLastPathComponent + "/nested-providers.yaml"
            try "llm:\n  providers:\n    bogus:\n      model: x\n"
                .write(toFile: nestedPath, atomically: true, encoding: .utf8)
            var nestedCfg = cfg
            nestedCfg.hermesConfig = nestedPath
            let nested = try Tools.hermes(nestedCfg).providers()
            check("a nested providers: section is not read as the top-level one",
                  !nested.contains("bogus"))

            // A top-level providers: mapping contributes provider names. The key
            // is deliberately outside the curated list, so the check can fail.
            let unionPath = (cfg.hermesConfig as NSString).deletingLastPathComponent + "/hermes-providers.yaml"
            try "providers:\n  together:\n    api_key: not-a-real-key\nplugins:\n  enabled:\n    - orca-status\n"
                .write(toFile: unionPath, atomically: true, encoding: .utf8)
            var unionCfg = cfg
            unionCfg.hermesConfig = unionPath
            let union = try Tools.hermes(unionCfg).providers()
            check("hermes providers include top-level YAML keys",
                  Set(union).isSuperset(of: ["together"]))

            // Hermes keeps no local model catalog; the configured model is the
            // one local entry, and it belongs only to its own provider.
            let openrouterModels = try he.models("openrouter")
            check("hermes lists the configured model for its provider",
                  openrouterModels.contains { $0.id == "deepseek/deepseek-v4.1-flash" })
            let otherModels = try he.models("openai")
            check("hermes lists no models for an unconfigured provider", otherModels.isEmpty)
        } catch {
            check("hermes adapter checks could not run: \(error)", false)
        }
    }

    /// Exercises the clawdbot adapter against a staged temp copy of
    /// Tests/fixtures. Never touches a real user path: the stub is staged into
    /// a temp dir and the log is a temp path. Throwing calls are hoisted out of
    /// `check`'s non-throwing autoclosure.
    private static func checkClawdbotAdapter() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")
            let cb = Tools.clawdbot(cfg)

            check("clawdbot detects from its state dir", cb.detect())

            let initial = try cb.currentModel()
            check("clawdbot reads primary from the object form",
                  initial == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))

            let listed = try cb.models("anthropic")
            check("clawdbot model list parses the CLI json",
                  listed.contains { $0.id == "anthropic/claude-opus-4-5" && $0.name == "Claude Opus 4.5 (latest)" })

            let providers = try cb.providers()
            check("clawdbot providers come from the CLI model keys",
                  providers == ["anthropic"])

            // The CLI is the JSON5-safe reader. These are verbatim captures of
            // its stdout; each shape is pinned separately so a parser that only
            // handled the object form fails the scalar check and vice versa.
            let objectForm = Tools.parseClawdbotModel(
                "{\n  \"primary\": \"anthropic/claude-opus-4-5\",\n  \"fallbacks\": [\n    \"openai/gpt-4o\"\n  ]\n}")
            check("clawdbot parses the object form from CLI stdout",
                  objectForm == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))
            let scalarForm = Tools.parseClawdbotModel("anthropic/claude-opus-4-5")
            check("clawdbot parses a bare scalar from CLI stdout",
                  scalarForm == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))
            check("clawdbot reports unset for the CLI's not-found message",
                  Tools.parseClawdbotModel("Config path not found: agents.defaults.model") == nil)
            check("clawdbot reports unset for empty CLI output",
                  Tools.parseClawdbotModel("") == nil)

            let root = (cfg.clawdbotConfig as NSString).deletingLastPathComponent
            // The real config is JSON5, so JSONSerialization throws on a comment.
            // The CLI must be tried first: this check fails if the file parse
            // runs first and its throw escapes.
            let json5Path = root + "/clawdbot-json5.json"
            try "{ // a comment\n  \"agents\": { \"defaults\": { \"model\": { \"primary\": \"anthropic/claude-opus-4-5\", \"fallbacks\": [\"openai/gpt-4o\"] } } }\n}\n"
                .write(toFile: json5Path, atomically: true, encoding: .utf8)
            var json5Paths = cfg
            json5Paths.clawdbotConfig = json5Path
            let json5Model = try Tools.clawdbot(json5Paths).currentModel()
            check("a comment-laden JSON5 config still reads through the CLI",
                  json5Model == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))

            let logPath = root + "/clawdbot-set.log"
            setenv("CLAWDBOT_STUB_LOG", logPath, 1)
            let cbBefore = try ConfigFile.read(cfg.clawdbotConfig)
            try cb.setModel(ToolModelRef(provider: "openrouter", model: "acme/opus-1"))
            let after = try ConfigFile.read(cfg.clawdbotConfig)
            check("clawdbot delegated the write to its CLI",
                  after.contains("openrouter/acme/opus-1"))
            check("clawdbot preserved fallbacks", after.contains("\"fallbacks\""))
            let fallbacksBefore = cbBefore.split(separator: "\n").first { $0.contains("\"fallbacks\"") }
            let fallbacksAfter = after.split(separator: "\n").first { $0.contains("\"fallbacks\"") }
            check("clawdbot preserved the fallbacks line byte-for-byte",
                  fallbacksBefore != nil && fallbacksBefore == fallbacksAfter)
            check("clawdbot created a backup",
                  FileManager.default.fileExists(atPath: cfg.clawdbotConfig + ".bak"))
            let log = (try? ConfigFile.read(logPath)) ?? ""
            check("clawdbot logged the CLI invocation",
                  log.contains("openrouter/acme/opus-1"))

            // An app launched from Finder gets a minimal PATH, so the candidate
            // list must be searched by absolute path. Each branch can fail.
            let stub = cfg.clawdbotBin
            check("clawdbot binary resolves from the first candidate when executable",
                  Tools.resolveClawdbotBinary(candidates: [stub, "/nonexistent/a"]) == stub)
            check("clawdbot binary falls back past a non-executable candidate",
                  Tools.resolveClawdbotBinary(candidates: ["/nonexistent/a", stub]) == stub)
            check("clawdbot binary returns nil when nothing is executable",
                  Tools.resolveClawdbotBinary(candidates: ["/nonexistent/a"]) == nil)

            // Detection must agree with the resolved binary, not a PATH-only
            // lookup: a Finder-launched app finds the CLI by absolute path with
            // no state directory. Injected candidates keep this off the real
            // PATH so the negative branch is deterministic.
            var noDir = cfg
            noDir.clawdbotDir = root + "/no-such-clawdbot-dir"
            check("clawdbot detects a resolved binary with no state dir",
                  Tools.clawdbot(noDir, candidates: [stub]).detect())
            check("clawdbot reports undetected with no dir and no binary",
                  !Tools.clawdbot(noDir, candidates: ["/nonexistent/clawdbot"]).detect())

            // The file-parse fallback is the read-only path taken when no CLI
            // can be launched. Injecting a dead candidate list is the only way
            // to reach it, because the real list resolves the staged stub. A
            // dedicated object-form copy keeps this independent of the staged
            // config that `setModel` rewrote above.
            let objectFormPath = root + "/clawdbot-object-fallback.json"
            try "{\n  \"agents\": {\n    \"defaults\": {\n      \"model\": {\n        \"primary\": \"anthropic/claude-opus-4-5\",\n        \"fallbacks\": [\"openai/gpt-4o\"]\n      }\n    }\n  }\n}\n"
                .write(toFile: objectFormPath, atomically: true, encoding: .utf8)
            var fallback = cfg
            fallback.clawdbotConfig = objectFormPath
            let fileObject = try Tools.clawdbot(fallback, candidates: ["/nonexistent/clawdbot"])
                .currentModel()
            check("with no runnable CLI, the object form is read from the file",
                  fileObject == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))

            let stringForm = root + "/clawdbot-string.json"
            try "{\n  \"agents\": {\n    \"defaults\": {\n      \"model\": \"anthropic/claude-opus-4-5\"\n    }\n  }\n}\n"
                .write(toFile: stringForm, atomically: true, encoding: .utf8)
            fallback.clawdbotConfig = stringForm
            let fileString = try Tools.clawdbot(fallback, candidates: ["/nonexistent/clawdbot"])
                .currentModel()
            check("with no runnable CLI, the string form is read from the file",
                  fileString == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))

            // "if the file parse also fails, report the error rather than hiding
            // it" — this must throw. `(try? …) == nil` would also pass on a
            // silent unset, so a flag distinguishes the two.
            let broken = root + "/clawdbot-broken.json"
            try "{ not json".write(toFile: broken, atomically: true, encoding: .utf8)
            fallback.clawdbotConfig = broken
            var unreadableThrew = false
            do { _ = try Tools.clawdbot(fallback, candidates: ["/nonexistent/clawdbot"]).currentModel() }
            catch { unreadableThrew = true }
            check("an unreadable config with no runnable CLI reports an error, not unset",
                  unreadableThrew)

            // An object without a `primary` string must read as unset, not as a
            // garbage scalar ref assembled from JSON punctuation.
            check("clawdbot reports unset for an object with no primary",
                  Tools.parseClawdbotModel("{\"fallbacks\": [\"openai/gpt-4o\"]}") == nil)
        } catch {
            check("clawdbot adapter checks could not run: \(error)", false)
        }
    }

    /// Exercises the tool registry and the `missing`/`unset`/`configured`
    /// mapping. pi, opencode and clawdbot each fall back to `PATH` and are
    /// installed on the reference machine, so for those a staged-absence check
    /// cannot fail; hermes's `detect()` is file-existence only, which makes its
    /// absent-config case machine-independent. The pure filter is tested with
    /// synthetic adapters so it does not depend on what is installed. Never
    /// touches a real user path — throwing calls are hoisted out of `check`'s
    /// non-throwing autoclosure.
    private static func checkRegistry() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")

            // The production overload, which Tasks 11 and 12 call. Hermes is the
            // one adapter with no `PATH` fallback, so pointing its config at a
            // missing file genuinely undetects it on any machine. Without these
            // two checks a wrong delegation here (`detected([])`, unfiltered, or
            // bound to another `paths`) would ship unnoticed.
            var headless = cfg
            headless.hermesConfig = (cfg.piSettings as NSString).deletingLastPathComponent + "/no-such-hermes.yaml"
            check("the production registry excludes a tool whose config is absent",
                  !Tools.detected(headless).contains { $0.id == "hermes" })
            check("the production registry still includes a tool whose config is present",
                  Tools.detected(cfg).contains { $0.id == "hermes" })

            // For pi, opencode and clawdbot a staged-absence check cannot work:
            // each falls back to `PATH` and is installed here. Hermes is covered
            // above. Test the pure filter with synthetic adapters so the
            // assertion is machine-independent.
            let yes = ToolAdapter(id: "yes", displayName: "yes", detect: { true }, currentModel: { nil },
                                  providers: { [] }, models: { _ in [] }, setModel: { _ in })
            let no = ToolAdapter(id: "no", displayName: "no", detect: { false }, currentModel: { nil },
                                 providers: { [] }, models: { _ in [] }, setModel: { _ in })
            check("the registry filters out undetected adapters",
                  Tools.detected([yes, no]).map(\.id) == ["yes"])
            check("the registry keeps a detected adapter",
                  Tools.detected([no, yes]).map(\.id) == ["yes"])
            check("all four adapters are registered",
                  Tools.all(cfg).map(\.id) == ["pi", "opencode", "hermes", "clawdbot"])

            let missing = try no.state()
            check("state reports missing for an undetected adapter", missing == .missing)
            let unset = try yes.state()
            check("state reports unset for a detected adapter with no model", unset == .unset)

            let piState = try Tools.pi(cfg).state()
            check("a configured tool reports its ref",
                  piState == .configured(ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash")))
            let hermesState = try Tools.hermes(cfg).state()
            check("hermes reports unset rather than throwing", hermesState == .unset)

            // An unreadable config must surface, not be quietly mapped to `.missing`.
            let broken = ToolAdapter(id: "broken", displayName: "broken", detect: { true },
                                     currentModel: { throw ConfigError.malformed("/nonexistent", "unreadable") },
                                     providers: { [] }, models: { _ in [] }, setModel: { _ in })
            var stateThrew = false
            do { _ = try broken.state() } catch { stateThrew = true }
            check("an unreadable config is reported, not mapped to missing", stateThrew)
        } catch {
            check("registry checks could not run: \(error)", false)
        }
    }

    /// Exercises the Keychain against the test-only `selftest` account, never
    /// the `openrouter` account the app itself writes. `set` upserts, so a
    /// leftover item from an interrupted run does not wedge the suite. The item
    /// is deleted again when the checks finish. Throwing calls are hoisted out
    /// of `check`'s non-throwing autoclosure.
    private static func checkKeychain() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")

            var setFailed = false
            do { try Keychain.set("test-value-not-a-real-key", account: "selftest") } catch { setFailed = true }
            check("keychain set succeeds", !setFailed)
            check("keychain round-trips", Keychain.get(account: "selftest") == "test-value-not-a-real-key")

            // Setting twice must overwrite, not fail: SecItemAdd on an existing
            // item returns errSecDuplicateItem. A plain add would fail here.
            var reSetFailed = false
            do { try Keychain.set("second-value-not-a-real-key", account: "selftest") } catch { reSetFailed = true }
            check("keychain set overwrites an existing value",
                !reSetFailed && Keychain.get(account: "selftest") == "second-value-not-a-real-key")

            var deleteThrew = false
            do { try Keychain.delete(account: "selftest") } catch { deleteThrew = true }
            check("keychain delete succeeds", !deleteThrew)
            check("keychain delete works", Keychain.get(account: "selftest") == nil)

            // Removing a key that is already gone is a no-op, not an error —
            // otherwise a second clear-key action would fail spuriously.
            var absentDeleteThrew = false
            do { try Keychain.delete(account: "selftest") } catch { absentDeleteThrew = true }
            check("deleting an absent key does not throw", !absentDeleteThrew)

            check("import finds the pi openrouter credential",
                Keychain.importFromPi(cfg) == "sk-or-v1-selftest-fixture-not-a-real-key")

            var noAuth = cfg
            noAuth.piAuth = (cfg.piSettings as NSString).deletingLastPathComponent + "/no-such-auth.json"
            check("import returns nil when the file is absent",
                Keychain.importFromPi(noAuth) == nil)
        } catch {
            check("keychain checks could not run: \(error)", false)
        }
        // Belt and braces: never leave the test account behind, even on failure.
        do { try Keychain.delete(account: "selftest") }
        catch { check("keychain cleanup failed: \(error)", false) }
    }

    /// Exercises the pure OpenRouter parsers and the 24-hour catalog cache
    /// against a temp file. No network I/O and no API key: the parsers are the
    /// testable seam and the cache path is injected. Never touches a real user
    /// path. Throwing calls are hoisted out of `check`'s non-throwing
    /// autoclosure, exactly as the other checks do.
    private static func checkOpenRouter() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")

            let parsed = try OpenRouter.parseCredits(Data(
                #"{"data":{"total_credits":344.11,"total_usage":327.007530314}}"#.utf8))
            check("credits parse", parsed.remaining.rounded(toPlaces: 2) == 17.10)
            // Pins rounding vs truncation: 17.102… truncates and rounds to the
            // same 17.10, so the check above cannot fail for this property.
            check("rounding rounds rather than truncating",
                  177.567.rounded(toPlaces: 2) == 177.57)
            check("credits parse keeps both fields",
                  parsed.totalCredits == 344.11 && parsed.totalUsage == 327.007530314)

            check("missing total_usage is an error, not a zero",
                  (try? OpenRouter.parseCredits(Data(#"{"data":{"total_credits":1}}"#.utf8))) == nil)
            // The two absent-field guards are separate lines; covering only one
            // leaves the other free to regress. `parseCredits` returns a
            // non-optional, so `try?` yields nil only when it throws.
            check("a missing total_credits is an error, not a zero",
                  (try? OpenRouter.parseCredits(Data(#"{"data":{"total_usage":1}}"#.utf8))) == nil)
            check("html error page is an error",
                  (try? OpenRouter.parseCredits(Data("<html>502</html>".utf8))) == nil)
            check("string-typed numbers are an error, not coerced",
                  (try? OpenRouter.parseCredits(Data(#"{"data":{"total_credits":"1","total_usage":"2"}}"#.utf8))) == nil)
            check("a non-JSON catalog is an error, not a crash",
                  (try? OpenRouter.parseCatalog(Data("<html>".utf8))) == nil)
            check("a catalog without names is an error",
                  (try? OpenRouter.parseCatalog(Data(#"{"data":[{"id":"x"}]}"#.utf8))) == nil)
            let catalog = try OpenRouter.parseCatalog(Data(
                #"{"data":[{"id":"a/b","name":"A"},{"id":"c/d","name":"C"}]}"#.utf8))
            check("a valid catalog parses both entries",
                  catalog.count == 2 && catalog[0].id == "a/b" && catalog[1].name == "C")

            let cachePath = (cfg.piSettings as NSString).deletingLastPathComponent + "/models-cache.json"

            var missingThrew = false
            var missingResult: [(id: String, name: String)]? = [(id: "sentinel", name: "sentinel")]
            do { missingResult = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { missingThrew = true }
            check("a missing catalog cache returns nil rather than throwing",
                  !missingThrew && missingResult == nil)

            let stale = "{\"fetchedAt\": \"2001-01-01T00:00:00Z\", \"models\": [{\"id\": \"a/b\", \"name\": \"A\"}]}"
            try stale.write(toFile: cachePath, atomically: true, encoding: .utf8)
            var staleThrew = false
            var staleResult: [(id: String, name: String)]? = nil
            do { staleResult = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { staleThrew = true }
            check("a catalog older than 24 hours is not served",
                  !staleThrew && staleResult == nil)

            let fresh = "{\"fetchedAt\": \"\(ISO8601DateFormatter().string(from: Date()))\", \"models\": [{\"id\": \"a/b\", \"name\": \"A\"}]}"
            try fresh.write(toFile: cachePath, atomically: true, encoding: .utf8)
            var freshResult: [(id: String, name: String)]? = nil
            do { freshResult = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { freshResult = nil }
            check("a catalog fresher than 24 hours is served", (freshResult?.count ?? 0) == 1)

            // A corrupt cache must throw, not be reported as absent or empty.
            try "{ not json".write(toFile: cachePath, atomically: true, encoding: .utf8)
            var corruptThrew = false
            do { _ = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { corruptThrew = true }
            check("a corrupt catalog cache throws rather than reading as empty", corruptThrew)
        } catch {
            check("openrouter checks could not run: \(error)", false)
        }
    }

    /// Exercises the settings model and the two pure presentation/alert
    /// functions against temp paths. Throwing calls are hoisted out of `check`'s
    /// non-throwing autoclosure. Never touches a real user path: every settings
    /// write goes to the staged temp root, and `AppConfig.path` is only ever
    /// compared against, never opened.
    private static func checkSettings() {
        do {
            let cfg = try ToolPaths().stagedInTempDir(from: "Tests/fixtures")
            let root = (cfg.piSettings as NSString).deletingLastPathComponent
            let settingsPath = root + "/app-config.json"

            var c = AppConfig.load(from: settingsPath)
            c.refreshMinutes = 42
            try c.save(to: settingsPath)
            check("app settings round-trip",
                  AppConfig.load(from: settingsPath).refreshMinutes == 42)

            var fields = AppConfig.load(from: settingsPath)
            fields.showMoneyInMenuBar = false; fields.showIconInMenuBar = false
            fields.notifyBelowEnabled = true; fields.notifyBelowAmount = 12.5
            try fields.save(to: settingsPath)
            let round = AppConfig.load(from: settingsPath)
            check("the menu bar and alert fields round-trip",
                  !round.showMoneyInMenuBar && !round.showIconInMenuBar && round.notifyBelowEnabled && round.notifyBelowAmount == 12.5)

            try "not json".write(toFile: settingsPath, atomically: true, encoding: .utf8)
            check("a corrupt settings file falls back to defaults",
                  AppConfig.load(from: settingsPath).refreshMinutes == 10)

            // The forward-compatibility pin: a missing key must cost only its
            // own default, not reset the keys the file did contain.
            try "{\"refreshMinutes\": 33}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
            let older = AppConfig.load(from: settingsPath)
            check("an older settings file keeps its values and gains the new defaults",
                  older.refreshMinutes == 33 && older.showMoneyInMenuBar && older.showIconInMenuBar && !older.notifyBelowEnabled)

            let defaults = AppConfig.load(from: root + "/config-that-does-not-exist.json")
            check("defaults show the money and icon and leave alerts off",
                  defaults.showMoneyInMenuBar && defaults.showIconInMenuBar && !defaults.notifyBelowEnabled)

            check("the selftest never targets the real settings path", settingsPath != AppConfig.path)

            // The status item must never be left with nothing to render, or it cannot be clicked.
            check("money and icon both on renders both", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: false) == (text: "$17.10", symbol: "dollarsign.circle"))
            check("money hidden renders the icon alone", MenuBarPresentation.of(showMoney: false, showIcon: true, balance: 17.1, error: false) == (text: nil, symbol: "dollarsign.circle"))
            check("icon hidden renders the money alone", MenuBarPresentation.of(showMoney: true, showIcon: false, balance: 17.1, error: false) == (text: "$17.10", symbol: nil))
            check("both hidden still renders something clickable", { let p = MenuBarPresentation.of(showMoney: false, showIcon: false, balance: 17.1, error: false); return p.text != nil || p.symbol != nil }())
            check("an error renders the em dash", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: true) == (text: "—", symbol: "dollarsign.circle"))
            check("a balance that was never fetched renders no money text", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: nil, error: false) == (text: nil, symbol: "dollarsign.circle"))

            // Alerts fire on a crossing, never on a state: the app refetches every 10 minutes.
            check("no alert when the feature is off", !BalanceAlert.shouldNotify(previous: 20, current: 3, threshold: 5, enabled: false, authorized: true))
            check("no alert when permission was refused", !BalanceAlert.shouldNotify(previous: 20, current: 3, threshold: 5, enabled: true, authorized: false))
            check("no alert at launch when already below the threshold", !BalanceAlert.shouldNotify(previous: nil, current: 3, threshold: 5, enabled: true, authorized: true))
            check("no alert when the fetch failed", !BalanceAlert.shouldNotify(previous: 20, current: nil, threshold: 5, enabled: true, authorized: true))
            check("no alert while already below", !BalanceAlert.shouldNotify(previous: 3, current: 2, threshold: 5, enabled: true, authorized: true))
            check("no alert when both readings are above", !BalanceAlert.shouldNotify(previous: 20, current: 19, threshold: 5, enabled: true, authorized: true))
            check("an alert on the crossing itself", BalanceAlert.shouldNotify(previous: 20, current: 3, threshold: 5, enabled: true, authorized: true))
            check("exactly at the threshold is not below it", !BalanceAlert.shouldNotify(previous: 20, current: 5, threshold: 5, enabled: true, authorized: true))
            check("one cent under the threshold alerts", BalanceAlert.shouldNotify(previous: 20, current: 4.99, threshold: 5, enabled: true, authorized: true))
        } catch {
            check("settings checks could not run: \(error)", false)
        }
    }

    /// Verifies stagedInTempDir copies within a temp dir, maps fixture names to
    /// the right fields, leaves absent fixtures absent, and chmods the stub.
    private static func checkStaging() {
        let fm = FileManager.default
        do {
            let source = fm.temporaryDirectory
                .appendingPathComponent("pcc-fixtures-\(UUID().uuidString)").path
            try fm.createDirectory(atPath: "\(source)/bin", withIntermediateDirectories: true)
            try "{\"defaultProvider\":\"openrouter\"}".write(
                toFile: "\(source)/pi-settings.json", atomically: true, encoding: .utf8)
            try "#!/bin/sh\n".write(
                toFile: "\(source)/bin/clawdbot", atomically: true, encoding: .utf8)

            let paths = try ToolPaths().stagedInTempDir(from: source)
            let root = (paths.piSettings as NSString).deletingLastPathComponent

            check("staged piSettings lands in the temp root",
                  paths.piSettings == "\(root)/pi-settings.json")
            check("staged piSettings copied its content",
                  (try? String(contentsOfFile: paths.piSettings, encoding: .utf8))?
                      .contains("openrouter") == true)
            check("absent fixture maps to a nonexistent temp path",
                  paths.opencodeConfig == "\(root)/opencode.json"
                      && !fm.fileExists(atPath: paths.opencodeConfig))
            check("clawdbotDir is the staged config's parent",
                  paths.clawdbotDir == root
                      && (paths.clawdbotConfig as NSString).deletingLastPathComponent == root)
            let attrs = try? fm.attributesOfItem(atPath: paths.clawdbotBin)
            let mode = attrs?[.posixPermissions] as? NSNumber
            check("staged clawdbot stub is executable 0755", mode?.intValue == 0o755)

            let other = try ToolPaths().stagedInTempDir(from: source)
            check("each staging call gets a fresh temp directory",
                  other.clawdbotDir != paths.clawdbotDir)

            try? fm.removeItem(atPath: source)
        } catch {
            check("staging check could not run: \(error)", false)
        }
    }
}
