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

    /// `@MainActor`: the adapter checks read the main-actor `CatalogCache`'s
    /// model-merge path, exactly as the app does.
    @MainActor
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
        checkRegistry()
        checkUsableKey()
        checkKeyStorage()
        checkOpenRouter()
        checkKeyUsageAndModelDetails()
        checkEndpointsAndFormatting()
        checkProviderSorting()
        checkSearchablePicker()
        checkSettings()
        checkHarnessTiles()
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
    /// `check`'s non-throwing autoclosure exactly as the other checks do.
    @MainActor
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
    @MainActor
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
    @MainActor
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


    /// Exercises the tool registry and the `missing`/`unset`/`configured`
    /// mapping. pi and opencode each fall back to `PATH` and are
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

            // For pi and opencode a staged-absence check cannot work:
            // each falls back to `PATH` and is installed here. Hermes is covered
            // above. Test the pure filter with synthetic adapters so the
            // assertion is machine-independent.
            let yes = ToolAdapter(id: "yes", displayName: "yes", symbol: "checkmark", detect: { true },
                                  currentModel: { nil }, providers: { [] }, models: { _ in [] }, setModel: { _ in })
            let no = ToolAdapter(id: "no", displayName: "no", symbol: "xmark", detect: { false },
                                 currentModel: { nil }, providers: { [] }, models: { _ in [] }, setModel: { _ in })
            check("the registry filters out undetected adapters",
                  Tools.detected([yes, no]).map(\.id) == ["yes"])
            check("the registry keeps a detected adapter",
                  Tools.detected([no, yes]).map(\.id) == ["yes"])
            check("all three adapters are registered",
                  Tools.all(cfg).map(\.id) == ["pi", "opencode", "hermes"])
            check("every registered adapter carries a non-empty symbol",
                  Tools.all(cfg).allSatisfy { !$0.symbol.isEmpty })
            check("each adapter carries its own SF Symbol",
                  Tools.all(cfg).map { "\($0.id)=\($0.symbol)" } == [
                      "pi=circle.hexagongrid",
                      "opencode=chevron.left.forwardslash.chevron.right",
                      "hermes=paperplane",
                  ])

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
            let broken = ToolAdapter(id: "broken", displayName: "broken", symbol: "exclamationmark",
                                     detect: { true },
                                     currentModel: { throw ConfigError.malformed("/nonexistent", "unreadable") },
                                     providers: { [] }, models: { _ in [] }, setModel: { _ in })
            var stateThrew = false
            do { _ = try broken.state() } catch { stateThrew = true }
            check("an unreadable config is reported, not mapped to missing", stateThrew)
        } catch {
            check("registry checks could not run: \(error)", false)
        }
    }

    /// Pins the one "a key exists" rule against literals, offline. Three
    /// directions, each separately falsifiable: `key != nil` (forgets the
    /// emptiness guard) flips the empty check alone; `key == nil` flips the nil
    /// check; `return false` flips the real-key check alone.
    private static func checkUsableKey() {
        check("a nil key is not usable", !isUsableAPIKey(nil))
        check("an empty key is not usable", !isUsableAPIKey(""))
        check("a non-empty key is usable", isUsableAPIKey("selftest-not-a-real-key"))
    }

    /// The opt-in Keychain backend, exercised against the test-only `selftest`
    /// account (never the `openrouter` account the app writes), plus the storage
    /// default. The item is removed again when the checks finish.
    private static func checkKeyStorage() {
        check("key storage defaults to the file", AppConfig().keyStorage == .file)

        var setFailed = false
        do { try Keychain.set("test-value-not-a-real-key", account: "selftest") } catch { setFailed = true }
        check("keychain set succeeds", !setFailed)
        check("keychain round-trips", Keychain.get(account: "selftest") == "test-value-not-a-real-key")

        var deleteThrew = false
        do { try Keychain.delete(account: "selftest") } catch { deleteThrew = true }
        check("keychain delete succeeds", !deleteThrew)
        check("keychain delete works", Keychain.get(account: "selftest") == nil)

        // Belt and braces: never leave the test account behind.
        do { try Keychain.delete(account: "selftest") }
        catch { check("keychain cleanup failed: \(error)", false) }
    }

    /// Pins `HarnessTiles`: only an added, healthy harness is a tile, a
    /// surviving healthy harness keeps its own row rather than being replaced by
    /// a stub, and the footer count is the number of row-backed failures
    /// regardless of `added`. The visibility checks fail if either half of the
    /// filter (membership, or the failure exclusion) is dropped; the
    /// surviving-row check fails if it filters the right ids but rebuilds them
    /// from scratch; the count checks pin that only rows (not row-less failures)
    /// are counted.
    private static func checkHarnessTiles() {
        let healthy = ToolRow(id: "pi", displayName: "pi", symbol: "circle.hexagongrid",
                              state: .configured(ToolModelRef(provider: "openrouter", model: "a/b")),
                              providers: ["openrouter"])
        let unadded = ToolRow(id: "opencode", displayName: "opencode",
                              symbol: "chevron.left.forwardslash.chevron.right",
                              state: .configured(ToolModelRef(provider: "openai", model: "c/d")),
                              providers: ["openai"])
        let failed = ToolRow(id: "hermes", displayName: "hermes", symbol: "paperplane",
                             state: .unset, providers: [])
        let errors = ["hermes": "unreadable"]

        let visible = HarnessTiles.visible(rows: [healthy, failed, unadded], added: ["pi"], failed: errors)
        check("only an added, healthy harness is a tile", visible.map(\.id) == ["pi"])
        // Catches a mutation that keeps the right ids but rebuilds the surviving
        // row as a default stub: `rows.filter { … }.map { ToolRow(id:…, displayName:…,
        // state: .unset, providers: []) }`. The id-only check
        // above passes for that mutation; this one does not.
        check("a healthy harness is kept as a tile with its own state",
              visible.count == 1
                && visible[0].displayName == "pi"
                && visible[0].symbol == "circle.hexagongrid"
                && visible[0].state == .configured(ToolModelRef(provider: "openrouter", model: "a/b"))
                && visible[0].providers == ["openrouter"])
        // Membership is the opt-in half of the rule: an unadded harness with an
        // unreadable-free config still must not tile.
        check("a healthy harness that was not added is excluded",
              HarnessTiles.visible(rows: [unadded], added: ["pi"], failed: [:]).isEmpty)
        // Health is the other half: adding a harness must not resurrect a failed
        // one.
        check("an added harness that failed discovery is excluded",
              HarnessTiles.visible(rows: [failed], added: ["hermes"], failed: errors).isEmpty)
        check("the failed count matches the excluded tiles",
              HarnessTiles.failedCount(rows: [healthy, failed], failed: errors) == 1)
        // A failure with no row must not inflate the footer.
        check("the failed count ignores failures that are not rows",
              HarnessTiles.failedCount(rows: [healthy], failed: ["hermes": "unreadable"]) == 0)
        // The count is independent of `added`: removing a failed harness from
        // the popover must not hide its failure.
        check("the failed count counts a failed row even when it was not added",
              HarnessTiles.failedCount(rows: [failed], failed: errors) == 1)
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

            // Item 3: the cache now persists the per-model details, so a fresh
            // cache serves the list and the prices without a fetch. Round-trip
            // through the same encoder/decoder the file path uses, with no file
            // and no network.
            let roundTrip = Catalog(
                models: [(id: "a/b", name: "A"), (id: "c/d", name: "C")],
                details: [
                    "a/b": ModelDetail(
                        promptPricePerToken: 0.000003,
                        completionPricePerToken: 0.000015,
                        contextLength: 200000),
                    "c/d": ModelDetail(
                        promptPricePerToken: nil,
                        completionPricePerToken: nil,
                        contextLength: nil),
                ])
            let roundTripped = try OpenRouter.parseCachedCatalog(
                OpenRouter.encodeCatalog(roundTrip))
            check("a cache round-trip carries the model list",
                  roundTripped?.models.count == 2
                      && roundTripped?.models[0].id == "a/b"
                      && roundTripped?.models[1].name == "C")
            check("a cache round-trip carries the model details",
                  roundTripped?.details["a/b"] == ModelDetail(
                      promptPricePerToken: 0.000003,
                      completionPricePerToken: 0.000015,
                      contextLength: 200000))
            // The short-circuit gate in `models()` is `hasModelDetails`. A
            // round-tripped cache with real prices must open it …
            check("a cache carrying detail data serves without a fetch",
                  roundTripped?.hasModelDetails == true)
            // … and a list-only cache (the pre-details shape) must not, so an
            // upgrade still fetches once and rewrites the file.
            let listOnlyData = Data(
                #"{"fetchedAt":"\#(ISO8601DateFormatter().string(from: Date()))","models":[{"id":"a/b","name":"A"}]}"#.utf8)
            let listOnly = try OpenRouter.parseCachedCatalog(listOnlyData)
            check("a list-only cache still fetches so its details are upgraded",
                  listOnly != nil && !listOnly!.hasModelDetails)
        } catch {
            check("openrouter checks could not run: \(error)", false)
        }
    }

    /// Pins the `/key` usage parser, the limit-bar accessor, and the
    /// model-detail parser. All are pure and none touches the network. The
    /// usage checks exist because a missing field read as zero would show a
    /// plausible, wrong `$0.00`; the limit checks exist because the bar must
    /// not appear without a real cap.
    @MainActor
    private static func checkKeyUsageAndModelDetails() {
        do {
            let usage = try OpenRouter.parseKeyUsage(Data(
                #"{"data":{"usage":118.444891034,"usage_daily":5.449676908,"usage_weekly":5.449676908,"usage_monthly":92.168432904,"limit":null,"limit_remaining":null,"limit_reset":"monthly","is_free_tier":false}}"#.utf8))
            check("key usage parses the three spend figures",
                  usage.usageDaily == 5.449676908
                      && usage.usageWeekly == 5.449676908
                      && usage.usageMonthly == 92.168432904)
            // A null cap is "no cap configured", not zero: the reset period is
            // still readable while the bar stays hidden.
            check("a null limit hides the bar and leaves the reset period readable",
                  usage.limit == nil && usage.limitRemaining == nil
                      && usage.limitReset == "monthly" && usage.limitProgress == nil)

            // Each guard is its own line; replacing one with `?? 0` compiles
            // and is caught only by its own check.
            check("a missing daily usage is an error, not a zero",
                  (try? OpenRouter.parseKeyUsage(Data(#"{"data":{"usage_weekly":1,"usage_monthly":1}}"#.utf8))) == nil)
            check("a missing weekly usage is an error, not a zero",
                  (try? OpenRouter.parseKeyUsage(Data(#"{"data":{"usage_daily":1,"usage_monthly":1}}"#.utf8))) == nil)
            check("a missing monthly usage is an error, not a zero",
                  (try? OpenRouter.parseKeyUsage(Data(#"{"data":{"usage_daily":1,"usage_weekly":1}}"#.utf8))) == nil)
            check("a non-JSON key response is an error, not a crash",
                  (try? OpenRouter.parseKeyUsage(Data("<html>401</html>".utf8))) == nil)

            // The newer optional fields: present values parse, and an absent one
            // is nil (omitted), never 0.
            let rich = try OpenRouter.parseKeyUsage(Data(
                #"{"data":{"usage_daily":1,"usage_weekly":2,"usage_monthly":3,"usage":99.5,"byok_usage":7.25,"is_free_tier":true,"label":"sk-or-v1-ab...cd","expires_at":"2027-12-31T23:59:59Z","free_model_daily_requests":{"used":12,"limit":50,"remaining":38}}}"#.utf8))
            check("key usage parses the optional fields",
                  rich.usageTotal == 99.5 && rich.byokUsage == 7.25
                      && rich.isFreeTier == true && rich.label == "sk-or-v1-ab...cd"
                      && rich.freeModelQuota == FreeModelQuota(used: 12, limit: 50, remaining: 38))
            check("expires_at parses to a date", rich.expiresAt != nil)
            let bare = try OpenRouter.parseKeyUsage(Data(
                #"{"data":{"usage_daily":1,"usage_weekly":1,"usage_monthly":1}}"#.utf8))
            check("absent optional key fields are nil, not zero",
                  bare.usageTotal == nil && bare.byokUsage == nil && bare.isFreeTier == nil
                      && bare.freeModelQuota == nil && bare.label == nil && bare.expiresAt == nil)
            let halfQuota = try OpenRouter.parseKeyUsage(Data(
                #"{"data":{"usage_daily":1,"usage_weekly":1,"usage_monthly":1,"free_model_daily_requests":{"used":1}}}"#.utf8))
            check("a half-reported free-model quota is treated as absent",
                  halfQuota.freeModelQuota == nil)
        } catch {
            check("key usage checks could not run: \(error)", false)
        }

        // `limitProgress` is the bar's only visibility rule.
        let noCap = KeyUsage(usageDaily: 1, usageWeekly: 1, usageMonthly: 1,
                             limit: nil, limitRemaining: 50, limitReset: nil)
        check("a null limit hides the bar even with a remaining figure",
              noCap.limitProgress == nil)
        let zeroCap = KeyUsage(usageDaily: 1, usageWeekly: 1, usageMonthly: 1,
                               limit: 0, limitRemaining: 0, limitReset: nil)
        check("a zero limit hides the bar rather than showing an empty one",
              zeroCap.limitProgress == nil)
        let noRemaining = KeyUsage(usageDaily: 1, usageWeekly: 1, usageMonthly: 1,
                                   limit: 100, limitRemaining: nil, limitReset: nil)
        check("a limit without a remaining figure hides the bar",
              noRemaining.limitProgress == nil)
        let capped = KeyUsage(usageDaily: 1, usageWeekly: 1, usageMonthly: 1,
                              limit: 100, limitRemaining: 80, limitReset: "monthly")
        check("a real cap yields its remaining/total pair",
              capped.limitProgress?.remaining == 80 && capped.limitProgress?.total == 100)

        // The popover's stat tiles.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 86_400.0
        let base = KeyUsage(usageDaily: 1.5, usageWeekly: 10.25, usageMonthly: 92.17)

        let withAccount = widgetTiles(
            credits: Credits(totalCredits: 100, totalUsage: 25.5), usage: base, now: now)
        check("the base tiles are today, week, month and account spent",
              withAccount.map(\.title) == ["Today", "Week", "Month", "Account spent"])
        check("the usage tiles format their figures",
              withAccount[0].value == "$1.50" && withAccount[1].value == "$10.25"
                  && withAccount[2].value == "$92.17")
        check("the account tile shows the share of purchased credits",
              withAccount[3].value == "$25.50" && withAccount[3].caption == "26% of $100.00")

        var full = base
        full.isFreeTier = true
        full.limit = 5
        full.limitRemaining = 2.12
        full.limitReset = "monthly"
        full.byokUsage = 3.5
        full.freeModelQuota = FreeModelQuota(used: 12, limit: 50, remaining: 38)
        full.expiresAt = now.addingTimeInterval(10 * day)
        let fullTiles = widgetTiles(credits: nil, usage: full, now: now)
        check("optional tiles appear only when their figure is present",
              fullTiles.map(\.title)
                  == ["Tier", "Today", "Week", "Month", "Key limit", "BYOK", "Free models", "Key"])
        let limit = fullTiles.first { $0.title == "Key limit" }
        check("the key-limit tile carries the cap, its reset and its bar",
              limit?.value == "$2.12" && limit?.caption == "of $5.00 · resets monthly"
                  && limit?.progressRemaining == 2.12 && limit?.progressTotal == 5)
        check("the free-model tile shows used of limit",
              fullTiles.first { $0.title == "Free models" }?.value == "12/50")

        // The tile layout: four to a row, with "Key limit" on its own row.
        check("key limit takes a full row and the rest pack four to a row",
              statRows(fullTiles).map { $0.map(\.title) }
                  == [["Tier", "Today", "Week", "Month"], ["Key limit"],
                      ["BYOK", "Free models", "Key"]])
        check("a short final row is still a single row",
              statRows([StatTile(title: "Today", value: "$1"),
                        StatTile(title: "Week", value: "$2")]).map { $0.map(\.title) }
                  == [["Today", "Week"]])
        check("rows wrap after four tiles",
              statRows((1...5).map { StatTile(title: "T\($0)", value: "$0") }).map(\.count)
                  == [4, 1])

        var expired = base
        expired.expiresAt = now.addingTimeInterval(-3600)
        check("a key expired this morning is an expired tile, not 0d",
              widgetTiles(credits: nil, usage: expired, now: now).last?.value == "expired")
        var far = base
        far.expiresAt = now.addingTimeInterval(200 * day)
        check("a key expiring far out has no expiry tile",
              !widgetTiles(credits: nil, usage: far, now: now).contains { $0.title == "Key" })
        check("no key and no credits means no tiles",
              widgetTiles(credits: nil, usage: nil, now: now).isEmpty)
        check("no purchased credits means no account tile",
              !widgetTiles(credits: Credits(totalCredits: 0, totalUsage: 5), usage: base, now: now)
                  .contains { $0.title == "Account spent" })

        do {
            let details = try OpenRouter.parseModelDetails(Data(
                #"{"data":[{"id":"anthropic/claude-fable","context_length":1000000,"pricing":{"prompt":"0.000003","completion":"0.000015","overrides":[{"min_prompt_tokens":200000,"prompt":"0.000006"}]}},{"id":"free/model","pricing":{}}]}"#.utf8))
            check("model details parse string prices and the context window",
                  details["anthropic/claude-fable"]?.promptPricePerToken == 0.000003
                      && details["anthropic/claude-fable"]?.completionPricePerToken == 0.000015
                      && details["anthropic/claude-fable"]?.contextLength == 1000000)
            // The entry must exist, or `?? 0` would still pass a nil-price check.
            check("a model with no price is nil, not zero",
                  details["free/model"] != nil
                      && details["free/model"]?.promptPricePerToken == nil
                      && details["free/model"]?.completionPricePerToken == nil)
            check("a model with no context window is nil, not zero",
                  details["free/model"] != nil
                      && details["free/model"]?.contextLength == nil)
            check("a non-JSON models response is an error, not a crash",
                  (try? OpenRouter.parseModelDetails(Data("<html>".utf8))) == nil)

            // OpenRouter's negative sentinel for variable/unknown pricing. Six
            // real models ship `"prompt": "-1"`, including `openrouter/auto`.
            // Without `value >= 0` in `price`, `openrouter/auto` renders
            // `-$1,000,000.00/M`.
            let sentinel = try OpenRouter.parseModelDetails(Data(
                #"{"data":[{"id":"openrouter/auto","pricing":{"prompt":"-1","completion":"-1"},"context_length":2000000}]}"#.utf8))
            check("a negative sentinel price is nil, not negative money",
                  sentinel["openrouter/auto"]?.promptPricePerToken == nil
                      && sentinel["openrouter/auto"]?.completionPricePerToken == nil)
            // The other side of the same guard: a genuinely free model prices
            // `"0"`, which must stay valid. `value > 0` would reject it.
            let zero = try OpenRouter.parseModelDetails(Data(
                #"{"data":[{"id":"free/model","pricing":{"prompt":"0","completion":"0"}}]}"#.utf8))
            check("a zero price is still valid, not rejected",
                  zero["free/model"]?.promptPricePerToken == 0
                      && zero["free/model"]?.completionPricePerToken == 0)
        } catch {
            check("model detail checks could not run: \(error)", false)
        }

        // The refresh replace rule, pure and offline. A fetch carrying no datum
        // must not blank prices already shown; one carrying a datum must replace
        // them. Each is its own check, so a single mutation (unconditional
        // replace, or unconditional keep) flips exactly one.
        let known = ["a/b": ModelDetail(
            promptPricePerToken: 0.000003,
            completionPricePerToken: nil,
            contextLength: nil)]
        check("an empty detail fetch leaves known prices untouched",
              CatalogCache.mergeDetails(existing: known, new: [:]) == known)
        // Not merely "non-empty": an all-nil map is the same "nothing" as an
        // empty one. Replacing on `!new.isEmpty` would wipe the known prices.
        let noDatum = ["c/d": ModelDetail(
            promptPricePerToken: nil, completionPricePerToken: nil, contextLength: nil)]
        check("a detail-less fetch leaves known prices untouched",
              CatalogCache.mergeDetails(existing: known, new: noDatum) == known)
        let fresh = ["c/d": ModelDetail(
            promptPricePerToken: 0.000001,
            completionPricePerToken: 0.000002,
            contextLength: 4096)]
        check("a detail-bearing fetch replaces known prices",
              CatalogCache.mergeDetails(existing: known, new: fresh) == fresh)
    }

    /// Pins the OpenRouter endpoint-layer parsers and the two unit formatters.
    /// All pure and offline: no network and no API key. A missing datum must be
    /// `nil` (omitted), never 0, and a malformed/HTML body must throw rather
    /// than parse as an empty table.
    private static func checkEndpointsAndFormatting() {
        check("a missing throughput is omitted, not zero", formatThroughput(nil) == nil)
        check("a throughput value renders as tokens per second",
              formatThroughput(45) == "45 tok/s")
        // The API's own schema says milliseconds while its example says 0.25
        // seconds; both branches are pinned so the heuristic cannot be dropped.
        check("a latency below 5 renders as seconds", formatLatency(0.25) == "0.25 s")
        check("a latency of 5 or more renders as milliseconds", formatLatency(250) == "250 ms")
        check("a missing latency is omitted, not zero", formatLatency(nil) == nil)

        do {
            // The live ZDR body is the endpoint-object shape: `model_id` + the
            // provider `tag`, not `model`/`provider`. The fixture must mirror
            // that or the parser passes offline and throws in production.
            let zdr = try OpenRouter.parseZDR(Data(
                #"{"data":[{"model_id":"anthropic/claude-fable-latest","tag":"together"},{"model_id":"openai/gpt-4","tag":"openai"}]}"#.utf8))
            check("parseZDR builds model_id pipe tag keys",
                  zdr == ["anthropic/claude-fable-latest|together", "openai/gpt-4|openai"])
            check("a malformed ZDR body throws",
                  (try? OpenRouter.parseZDR(Data("<html>403</html>".utf8))) == nil)
            check("a ZDR entry without model_id/tag throws rather than keying wrong",
                  (try? OpenRouter.parseZDR(Data(#"{"data":[{"provider":"x"}]}"#.utf8))) == nil)

            let providers = try OpenRouter.parseProviders(Data(
                #"{"data":[{"slug":"together","privacy_policy_url":"https://together.example/privacy","terms_of_service_url":"https://together.example/tos"},{"slug":"openai","privacy_policy_url":null,"terms_of_service_url":null}]}"#.utf8))
            check("parseProviders keys by slug and carries both URLs",
                  providers["together"]?.privacy == "https://together.example/privacy"
                      && providers["together"]?.tos == "https://together.example/tos")
            check("a provider with null URLs parses as nil, not empty strings",
                  providers["openai"]?.privacy == nil && providers["openai"]?.tos == nil)
            // `/providers` keys on the base slug, but an endpoint tag can carry
            // a region suffix (`google-vertex/global`), so the join must fall
            // back to the base slug or those rows lose their links.
            check("a region-scoped tag falls back to the base provider slug",
                  OpenRouter.providerInfo(forSlug: "together/global", in: providers)?.privacy
                      == "https://together.example/privacy")
            check("an unknown slug with no base entry has no provider info",
                  OpenRouter.providerInfo(forSlug: "nobody/global", in: providers) == nil)
            check("a malformed providers body throws",
                  (try? OpenRouter.parseProviders(Data("<html>403</html>".utf8))) == nil)

            let endpoints = try OpenRouter.parseModelEndpoints(Data(
                #"{"data":{"id":"anthropic/claude-fable-latest","endpoints":[{"tag":"together","provider_name":"Together","pricing":{"prompt":"0.000003","completion":"0.000015"},"throughput_last_30m":{"p50":45},"latency_last_30m":{"p50":0.25},"context_length":200000,"quantization":"fp8"},{"provider_name":"DeepInfra","pricing":{"prompt":"-1","completion":"-1"}}]}}"#.utf8),
                zdrKeys: ["anthropic/claude-fable-latest|together"])
            check("endpoints parse decimal-string prices",
                  endpoints.count == 2
                      && endpoints[0].promptPricePerToken == 0.000003
                      && endpoints[0].completionPricePerToken == 0.000015)
            check("an endpoint reads tag as the provider slug",
                  endpoints[0].providerSlug == "together" && endpoints[0].providerName == "Together")
            check("a missing tag falls back to the lowercased provider name",
                  endpoints[1].providerSlug == "deepinfra" && endpoints[1].providerName == "DeepInfra")
            check("a negative sentinel price is nil, not negative money",
                  endpoints[1].promptPricePerToken == nil && endpoints[1].completionPricePerToken == nil)
            check("a ZDR key marks its endpoint",
                  endpoints[0].zdr && !endpoints[1].zdr)
            check("missing throughput, latency, context and quantization are nil, not zero",
                  endpoints[1].throughputP50 == nil && endpoints[1].latencyP50 == nil
                      && endpoints[1].contextLength == nil && endpoints[1].quantization == nil)
            check("an HTML body throws rather than parsing as an empty table",
                  (try? OpenRouter.parseModelEndpoints(Data("<html>403</html>".utf8), zdrKeys: [])) == nil)
        } catch {
            check("endpoint parse checks could not run: \(error)", false)
        }
    }

    /// Pins the `Table` sort keys: an optional numeric datum maps to the largest
    /// finite value, so ascending sorts it last (a missing price is not a zero),
    /// and a ZDR endpoint sorts before a non-ZDR one.
    private static func checkProviderSorting() {
        func endpoint(_ name: String, prompt: Double?, zdr: Bool = false) -> EndpointInfo {
            EndpointInfo(providerSlug: name.lowercased(), providerName: name,
                         promptPricePerToken: prompt, completionPricePerToken: nil,
                         throughputP50: nil, latencyP50: nil, contextLength: nil,
                         quantization: nil, zdr: zdr, privacyPolicyURL: nil,
                         termsOfServiceURL: nil)
        }
        let rows = [endpoint("Beta", prompt: 3),
                    endpoint("Alpha", prompt: nil, zdr: true),
                    endpoint("Gamma", prompt: 1)]

        check("a missing price maps to the largest sort key",
              endpoint("Alpha", prompt: nil).promptOrder == .greatestFiniteMagnitude)
        check("a present price uses its own value",
              endpoint("Gamma", prompt: 1).promptOrder == 1)
        let byPrice = rows.sorted(using: [KeyPathComparator(\EndpointInfo.promptOrder)])
        check("price sort ascending puts the missing price last",
              byPrice.map(\.providerName) == ["Gamma", "Beta", "Alpha"])
        check("a ZDR endpoint sorts before a non-ZDR one",
              endpoint("A", prompt: 1, zdr: true).zdrOrder < endpoint("B", prompt: 1).zdrOrder)
        check("provider name is a working sort key",
              rows.sorted(using: [KeyPathComparator(\EndpointInfo.providerName)]).map(\.providerName)
                  == ["Alpha", "Beta", "Gamma"])
    }

    /// Pins the searchable picker's commit rule: a typed name or id resolves to
    /// the option's id, and anything else is kept verbatim as a free-form id (the
    /// locally-configured-model case). Pure, so it runs without a popover.
    private static func checkSearchablePicker() {
        let options = [(id: "openrouter/anthropic/claude-fable-latest", name: "Anthropic: Claude Fable"),
                       (id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash")]
        check("a typed display name resolves to its id",
              resolveModelSelection("Anthropic: Claude Fable", in: options)
                  == "openrouter/anthropic/claude-fable-latest")
        check("a typed id resolves to itself",
              resolveModelSelection("deepseek/deepseek-v4.1-flash", in: options)
                  == "deepseek/deepseek-v4.1-flash")
        check("unmatched text is kept verbatim as a free-form id",
              resolveModelSelection("  local/model:x  ", in: options) == "local/model:x")
        check("an empty selection resolves to empty, never an arbitrary option",
              resolveModelSelection("", in: options) == "")
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
            c.apiKey = "sk-or-v1-file-key"
            try c.save(to: settingsPath)
            let loaded = AppConfig.load(from: settingsPath)
            check("app settings round-trip", loaded.refreshMinutes == 42)
            check("the api key round-trips through the settings file",
                  loaded.apiKey == "sk-or-v1-file-key")
            // The key is plain text here, so the file must stay owner-only.
            let fileMode = (try? FileManager.default.attributesOfItem(atPath: settingsPath))?[.posixPermissions] as? NSNumber
            check("the settings file is written owner-only (0600)", fileMode?.intValue == 0o600)

            var registry = AppConfig.load(from: settingsPath)
            registry.addedHarnesses = ["pi", "hermes"]
            registry.providerOnly = ["deepseek/deepseek-v4.1-flash": ["together"]]
            registry.keyStorage = .keychain
            try registry.save(to: settingsPath)
            let registryRound = AppConfig.load(from: settingsPath)
            check("added harnesses, provider-only and key storage round-trip",
                  registryRound.addedHarnesses == ["pi", "hermes"]
                      && registryRound.providerOnly == ["deepseek/deepseek-v4.1-flash": ["together"]]
                      && registryRound.keyStorage == .keychain)

            var fields = AppConfig.load(from: settingsPath)
            fields.showMoneyInMenuBar = false; fields.showIconInMenuBar = false
            fields.hidesAmountInMenuBar = true
            fields.notifyBelowEnabled = true; fields.notifyBelowAmount = 12.5
            try fields.save(to: settingsPath)
            let round = AppConfig.load(from: settingsPath)
            check("the menu bar and alert fields round-trip",
                  !round.showMoneyInMenuBar && !round.showIconInMenuBar && round.hidesAmountInMenuBar && round.notifyBelowEnabled && round.notifyBelowAmount == 12.5)

            try "not json".write(toFile: settingsPath, atomically: true, encoding: .utf8)
            check("a corrupt settings file falls back to defaults",
                  AppConfig.load(from: settingsPath).refreshMinutes == 10)

            // The forward-compatibility pin: a removed key must be ignored,
            // and every other setting the file carried must survive the upgrade.
            try "{\"refreshMinutes\": 33, \"hiddenTools\": [\"pi\"], \"binaryPathOverrides\": {\"legacy\": \"/opt/legacy\"}, \"showMoneyInMenuBar\": false, \"notifyBelowAmount\": 7.5}"
                .write(toFile: settingsPath, atomically: true, encoding: .utf8)
            let older = AppConfig.load(from: settingsPath)
            check("an old settings file with removed keys keeps every other setting",
                  older.refreshMinutes == 33 && !older.showMoneyInMenuBar && older.showIconInMenuBar
                      && !older.hidesAmountInMenuBar && !older.notifyBelowEnabled
                      && older.notifyBelowAmount == 7.5 && !older.launchAtLogin
                      && older.addedHarnesses.isEmpty && older.providerOnly.isEmpty
                      && older.apiKey == nil && older.keyStorage == .file)

            // A present-but-mistyped value must cost only its own field: without
            // `try?` per field the whole decode throws and refreshMinutes resets
            // to 10, so this check fails if the guard is removed.
            try "{\"refreshMinutes\": 33, \"notifyBelowAmount\": \"not-a-number\"}"
                .write(toFile: settingsPath, atomically: true, encoding: .utf8)
            let mistyped = AppConfig.load(from: settingsPath)
            check("a mistyped value falls back to its own default and keeps the rest",
                  mistyped.notifyBelowAmount == 5.0 && mistyped.refreshMinutes == 33)

            let defaults = AppConfig.load(from: root + "/config-that-does-not-exist.json")
            check("defaults show the money and icon and leave alerts off",
                  defaults.showMoneyInMenuBar && defaults.showIconInMenuBar && !defaults.notifyBelowEnabled)

            check("the selftest never targets the real settings path", settingsPath != AppConfig.path)

            // Only row-affecting edits may rebuild rows, or a keystroke in the
            // interval/threshold/toggle fields spawns a CLI on the main thread.
            let base = AppConfig()
            var interval = base; interval.refreshMinutes = 99
            check("a refresh-interval change does not rebuild rows",
                  !ConfigChange.affectsRows(from: base, to: interval))
            var threshold = base; threshold.notifyBelowAmount = 1
            check("an alert-threshold change does not rebuild rows",
                  !ConfigChange.affectsRows(from: base, to: threshold))
            var menuToggle = base; menuToggle.showMoneyInMenuBar = false
            check("a menu-bar toggle does not rebuild rows",
                  !ConfigChange.affectsRows(from: base, to: menuToggle))
            check("the hide-amount setting defaults off",
                  !AppConfig().hidesAmountInMenuBar && !defaults.hidesAmountInMenuBar)
            var login = base; login.launchAtLogin = true
            check("a launch-at-login change does not rebuild rows",
                  !ConfigChange.affectsRows(from: base, to: login))
            var added = base; added.addedHarnesses = ["pi"]
            check("adding a harness rebuilds the rows",
                  ConfigChange.affectsRows(from: base, to: added))
            var providerOnly = base; providerOnly.providerOnly = ["a/b": ["x"]]
            check("a provider-only change does not rebuild rows",
                  !ConfigChange.affectsRows(from: base, to: providerOnly))

            // The status item must never be left with nothing to render, or it cannot be clicked.
            check("money and icon both on renders both", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: false) == (text: "$17.10", symbol: "dollarsign.circle"))
            check("money hidden renders the icon alone", MenuBarPresentation.of(showMoney: false, showIcon: true, balance: 17.1, error: false) == (text: nil, symbol: "dollarsign.circle"))
            check("icon hidden renders the money alone", MenuBarPresentation.of(showMoney: true, showIcon: false, balance: 17.1, error: false) == (text: "$17.10", symbol: nil))
            check("both hidden still renders something clickable", { let p = MenuBarPresentation.of(showMoney: false, showIcon: false, balance: 17.1, error: false); return p.text != nil || p.symbol != nil }())
            check("an error renders the em dash", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: true) == (text: "—", symbol: "dollarsign.circle"))
            check("a balance that was never fetched renders no money text", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: nil, error: false) == (text: nil, symbol: "dollarsign.circle"))
            check("money shown, icon hidden and no balance yet still renders the icon", MenuBarPresentation.of(showMoney: true, showIcon: false, balance: nil, error: false) == (text: nil, symbol: "dollarsign.circle"))
            check("money shown, icon hidden and an error still renders the money", MenuBarPresentation.of(showMoney: true, showIcon: false, balance: 17.1, error: true) == (text: "—", symbol: nil))

            // Redaction replaces only the amount, with exactly `...$`. Each
            // check flips separately: dropping `redacted` from the amount branch
            // fails the first; applying it to the em dash fails the third;
            // reviving a figure for the never-fetched case fails the fifth.
            check("a redacted amount renders as exactly three dots and a dollar sign", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: false, redacted: true) == (text: "...$", symbol: "dollarsign.circle"))
            check("an unredacted amount renders the real figure", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: false, redacted: false) == (text: "$17.10", symbol: "dollarsign.circle"))
            check("an error still shows the em dash while redacted", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: true, redacted: true) == (text: "—", symbol: "dollarsign.circle"))
            check("a redacted amount with the icon hidden still renders the dots", MenuBarPresentation.of(showMoney: true, showIcon: false, balance: 17.1, error: false, redacted: true) == (text: "...$", symbol: nil))
            check("a never-fetched balance is still nil while redacted", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: nil, error: false, redacted: true) == (text: nil, symbol: "dollarsign.circle"))

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
    /// the right fields, and leaves absent fixtures absent.
    private static func checkStaging() {
        let fm = FileManager.default
        do {
            let source = fm.temporaryDirectory
                .appendingPathComponent("pcc-fixtures-\(UUID().uuidString)").path
            try fm.createDirectory(atPath: source, withIntermediateDirectories: true)
            try "{\"defaultProvider\":\"openrouter\"}".write(
                toFile: "\(source)/pi-settings.json", atomically: true, encoding: .utf8)

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

            let other = try ToolPaths().stagedInTempDir(from: source)
            check("each staging call gets a fresh temp directory",
                  other.piSettings != paths.piSettings)

            try? fm.removeItem(atPath: source)
        } catch {
            check("staging check could not run: \(error)", false)
        }
    }
}
