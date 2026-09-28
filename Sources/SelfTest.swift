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
