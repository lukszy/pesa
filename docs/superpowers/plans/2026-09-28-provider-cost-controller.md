# Provider Cost Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app showing the OpenRouter balance and letting the user view and change the configured model of pi, opencode, hermes, and clawdbot/OpenClaw.

**Architecture:** One `LSUIElement` AppKit process. A flat table of four tool adapters, each with an injected `ToolPaths` so tests never touch real config. Adapters prefer a targeted key edit over parse-and-reserialize because clawdbot's config is JSON5 and the others must keep their formatting. `swiftc` builds the binary; a shell script assembles the `.app`.

**Tech Stack:** Swift 6.3.3, AppKit, SwiftUI, Security, ServiceManagement, Foundation `URLSession`. No third-party dependencies, no SwiftPM, no XCTest.

**Spec:** `docs/superpowers/specs/2026-09-28-provider-cost-controller-design.md`

## Global Constraints

- Executable and app name: `ProviderCostController`. Bundle identifier `local.provider-cost-controller`.
- Deployment target macOS 13.0. Build with `swiftc`, never SwiftPM (`swift package` cannot link `PackageDescription` under Command Line Tools).
- Build command: `swiftc -O -o .build/ProviderCostController Sources/*.swift -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -framework UserNotifications -target $(uname -m)-apple-macosx13.0`
- No XCTest. All automated checks are `assert`-based, run by `--selftest`, exit 0 on pass and 1 on failure.
- No third-party dependencies.
- Balance = `total_credits − total_usage` from `GET /api/v1/credits`, displayed to exactly two decimals (`$17.10`).
- Menu bar title on any fetch failure: `—` (U+2014 EM DASH).
- Model references split on the **first** `/` only.
- Every tool config write: copy original to `<file>.bak`, then write via temp file plus atomic rename.
- The API key lives only in the Keychain (service `provider-cost-controller`, account `openrouter`). It must never be written to a file, logged, or included in an error message.
- App settings file: `~/Library/Application Support/ProviderCostController/config.json`.
- Never write placeholder code for anything in the spec's Non-goals section.
- The selftest must never read or write a real user path (`~/.pi`, `~/.config`, `~/.hermes`, `~/.clawdbot`, `~/Library`). Every check runs against `ToolPaths.stagedInTempDir`.
- No check may be written so that it cannot fail (for example `<condition> || true`). A vacuous check is a defect.

## Review Focus

These are the failure modes the spec implies but no task's own tests cover. Each is pinned to the task that owns the code.

1. **A tool config that cannot be written** (read-only file, read-only parent directory, root-owned). Expected: a clear error, the original file byte-identical, and the other three tools still usable. → Task 4.
2. **`agents.defaults.model` stored as an object with `fallbacks`** (clawdbot). Expected: `primary` is set and the `fallbacks` array survives byte-for-byte. → Task 7.
3. **Model ids with extra separators** — `ollama/qwen3.8:latest`, `openrouter/anthropic/claude-fable-latest`. Expected: provider is the first segment, the model is everything after it, nothing truncated or re-joined. → Task 3.
4. **The file changed on disk between read and write** (another process edited it). Expected: the write does not silently clobber; `.bak` holds the state immediately before the write. → Task 3.
5. **OpenRouter returns a non-2xx, an HTML error page, or JSON missing `total_credits`.** Expected: no crash, error surfaced in the popover, previous balance kept and labelled with its age. → Task 10.
6. **A settings file written by an earlier version of this app, missing the keys that were added later.** Expected: the user's existing values survive and only the absent keys take their defaults — decoding the whole struct must not fail, because a failed decode falls back to *all* defaults and would silently reset every setting the user had chosen. This will really happen: the app owns this file and its schema grows across versions. → Task 11.

---

### Task 1: Build, packaging, and status item skeleton

**Files:**
- Create: `scripts/build.sh`, `scripts/build-app.sh`, `Sources/main.swift`, `Resources/Info.plist`

**Interfaces:**
- Produces: `.build/ProviderCostController` (binary), `ProviderCostController.app`, and a `--probe` flag that prints status item facts and exits 0.

- [ ] **Step 1: Write `scripts/build.sh`**

Exports one variable and builds the binary with the exact command from Global Constraints. It must `set -euo pipefail` and `mkdir -p .build`.

- [ ] **Step 2: Write `Resources/Info.plist`**

Keys: `CFBundleExecutable` `ProviderCostController`, `CFBundleIdentifier` `local.provider-cost-controller`, `CFBundleName`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `0.1.0`, `LSMinimumSystemVersion` `13.0`, `LSUIElement` true.

- [ ] **Step 3: Write `scripts/build-app.sh`**

Calls `scripts/build.sh`, then `rm -rf ProviderCostController.app`, copies the binary to `Contents/MacOS/`, copies `Resources/Info.plist` to `Contents/Info.plist`, and runs `codesign -s - --force ProviderCostController.app`.

- [ ] **Step 4: Write `Sources/main.swift` with the status item and `--probe`**

If `CommandLine.arguments.contains("--probe")`: build the `NSStatusItem`, print whether the item, its button, and the button's window exist and whether the window is visible, then exit 0. Otherwise set `.accessory` activation policy and run. This flag exists so the GUI can be verified without screen recording permission.

```swift
func runProbe() -> Int32   // prints "statusItem=true button=true window=true visible=true", returns 0
```

- [ ] **Step 5: Verify the build and the status item**

Run: `./scripts/build-app.sh && open ProviderCostController.app && sleep 5 && pgrep -f "ProviderCostController.app"`
Expected: the app is built, launched, and the process is listed.
Run: `./.build/ProviderCostController --probe`
Expected: all four facts `true`, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add scripts Sources/main.swift Resources/Info.plist
git commit -m "feat: menu bar app skeleton, build and app-bundle scripts"
```

---

### Task 2: Self-test harness

**Files:**
- Create: `Sources/SelfTest.swift`, `Sources/ToolPaths.swift`, `Tests/fixtures/.gitkeep`
- Modify: `Sources/main.swift` (dispatch `--selftest`)

**Interfaces:**
- Produces: `SelfTest.run() -> Int32` (0 pass, 1 fail), `SelfTest.check(_ name: String, _ condition: @autoclosure () -> Bool)`, and `SelfTest.countFailures(_ checks: [(name: String, condition: Bool)]) -> Int`.
- Produces: `struct ToolPaths` with all file locations, plus `static var real: ToolPaths` and `func stagedInTempDir(from fixtures: String) throws -> ToolPaths`. Every later adapter takes a `ToolPaths`.

- [ ] **Step 1: Write the failing test**

Add to `Sources/SelfTest.swift` a `run()` that calls `check("harness detects a false condition", 1 == 2)`. Dispatch `--selftest` from `main.swift` before any AppKit work.

- [ ] **Step 2: Run it to make sure it fails**

Run: `./scripts/build.sh && ./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: `FAIL harness detects a false condition`, `exit=1`.

- [ ] **Step 3: Fix the check and add `ToolPaths`**

Change the deliberately failing canary into a **durable** failure-accounting check. The Global Constraint forbids a check that cannot fail, so `check("…", 1 == 1)` must not ship. Extract the counting into a shared function, have `check` record results and `run()` report and aggregate through it, and assert on it:

```swift
SelfTest.check("harness counts a failing check",
    SelfTest.countFailures([("deliberate false", false), ("deliberate true", true)]) == 1)
```

`check(_:_:)` must stay a static function with that exact signature — every later task calls it. `countFailures` must be the same accounting path `run()` uses, so the canary fails if the accounting ever regresses.

Then add `ToolPaths` fields: `piSettings`, `piAuth`, `piModels`, `piModelsStore`, `opencodeConfig`, `opencodeAuth`, `hermesConfig`, `hermesEnv`, `clawdbotConfig`, `clawdbotDir`, `clawdbotBin`. `real` resolves the paths from the spec's table.

`stagedInTempDir(from:)` copies the fixture directory into a fresh temp directory and returns a `ToolPaths` pointing at the copies, using this fixed fixture-name → field mapping:

| fixture | ToolPaths field |
|---|---|
| `pi-settings.json` | `piSettings` |
| `pi-auth.json` | `piAuth` |
| `pi-models.json` | `piModels` |
| `pi-models-store.json` | `piModelsStore` |
| `opencode.json` | `opencodeConfig` |
| `opencode-auth.json` | `opencodeAuth` |
| `hermes-config.yaml` | `hermesConfig` |
| `hermes.env` | `hermesEnv` |
| `clawdbot.json` | `clawdbotConfig`; `clawdbotDir` is its parent directory |
| `bin/clawdbot` | `clawdbotBin`, staged mode `0755` |

A fixture that is absent maps to a path inside the temp directory that does not exist. The staged `bin/clawdbot` must be made executable (`chmod 0755`) after copying, or Task 7 cannot launch it. `stagedInTempDir` must not read or write any path outside its temp directory.

- [ ] **Step 4: Run it to verify it passes**

Run: `./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: `PASS harness counts a failing check`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SelfTest.swift Sources/ToolPaths.swift Sources/main.swift Tests/fixtures
git commit -m "test: assert-based self-test harness and injectable tool paths"
```

---

### Task 3: Config edit primitives

**Files:**
- Create: `Sources/ConfigFile.swift`, `Tests/fixtures/pi-settings.json`, `Tests/fixtures/opencode.json`, `Tests/fixtures/hermes-config.yaml`, `Tests/fixtures/clawdbot.json`
- Modify: `Sources/SelfTest.swift`

**Fixture contents — binding.** Tasks 4, 5, 6, and 7 assert against these exact values, so the fixtures this task creates must match them. They are small on purpose; do not add extra keys beyond what is shown, except where a comment says to.

`Tests/fixtures/pi-settings.json` — must keep `defaultThinkingLevel`, because Task 4 asserts the rest of the file survived a write:

```json
{
  "theme": "dark",
  "defaultProvider": "openrouter",
  "defaultModel": "deepseek/deepseek-v4.1-flash",
  "defaultThinkingLevel": "medium"
}
```

`Tests/fixtures/opencode.json` — the model value is the real local one, and it carries a `provider` block so Task 5's provider union has something in it:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "omlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "oMLX",
      "options": { "baseURL": "http://127.0.0.1:8000/v1", "apiKey": "not-a-real-key" },
      "models": { "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit": { "name": "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit" } }
    },
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LM Studio",
      "options": { "baseURL": "http://127.0.0.1:1234/v1" }
    }
  },
  "model": "omlx/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"
}
```

`Tests/fixtures/hermes-config.yaml` — Task 6 asserts `orca-status` survives the edit. This one must have a top-level `model:` line **absent**, because Task 6 asserts hermes reports `unset` before the write:

```yaml
plugins:
  enabled:
    - orca-status
```

`Tests/fixtures/clawdbot.json` — the object form with `fallbacks`, which Review Focus #2 requires Task 7 to preserve:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-opus-4-5",
        "fallbacks": ["anthropic/claude-sonnet-4-5", "openai/gpt-4o"]
      }
    }
  }
}
```

Fixtures must contain no real credentials. Use obvious placeholders such as `not-a-real-key`.

**Interfaces:**
- Produces: `enum ConfigFile` with `read(_ path: String) throws -> String`, `backup(_ path: String) throws`, `atomicWrite(_ contents: String, to path: String) throws`, `setJSONString(_ key: String, to value: String, in path: String) throws -> String`, `setYAMLScalar(_ key: String, to value: String, in path: String) throws -> String` (each returns the new contents in addition to writing).
- Produces: `struct ToolModelRef: Equatable` with `provider`, `model`, `var qualified: String` and `static func parse(_ raw: String) -> ToolModelRef?`.
- Produces: `enum ConfigError: Error` with cases `missing(path)`, `unreadable(path, String)`, `malformed(path, String)`, `write(path, String)`.

- [ ] **Step 1: Write the failing tests**

In `SelfTest.run()`, using a staged temp copy of `Tests/fixtures/opencode.json`. Obtain the staged paths with `ToolPaths().stagedInTempDir(from: "Tests/fixtures")`; the `--selftest` run is invoked from the repository root, so that relative path resolves. That fixture will contain `"model": "omlx/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"`, a `provider` block containing `omlx` and `lmstudio`, and the string `@ai-sdk/openai-compatible`, so Tasks 3, 5, and 11 all read the same file consistently:

```swift
SelfTest.check("parse splits on the first slash only",
    ToolModelRef.parse("openrouter/anthropic/claude-fable-latest")?.model == "anthropic/claude-fable-latest")
SelfTest.check("parse keeps a colon inside the model",
    ToolModelRef.parse("ollama/qwen3.8:latest")?.model == "qwen3.8:latest")
let before = try ConfigFile.read(cfg.opencodeConfig)
try ConfigFile.setJSONString("model", to: "openrouter/acme/opus-1", in: cfg.opencodeConfig)
let after = try ConfigFile.read(cfg.opencodeConfig)
SelfTest.check("only the model value changed", after.replacingOccurrences(of: "openrouter/acme/opus-1", with: "omlx/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit") == before)
SelfTest.check("backup holds the pre-write bytes", try ConfigFile.read(cfg.opencodeConfig + ".bak") == before)
SelfTest.check("missing file is reported, not crashed", (try? ConfigFile.setJSONString("model", to: "x", in: "/nonexistent/y.json")) == nil)

// A fresh install may have no top-level key at all. Writing must insert it, not silently no-op.
let scratch = (cfg.piSettings as NSString).deletingLastPathComponent + "/no-model-key.json"
try "{\n  \"theme\": \"dark\"\n}\n".write(toFile: scratch, atomically: true, encoding: .utf8)
try ConfigFile.setJSONString("model", to: "openrouter/acme/opus-1", in: scratch)
SelfTest.check("an absent JSON key is inserted, not ignored",
    (try ConfigFile.read(scratch)).contains("\"model\": \"openrouter/acme/opus-1\""))
SelfTest.check("inserting the key kept the existing keys",
    (try ConfigFile.read(scratch)).contains("\"theme\": \"dark\""))

// The key must be matched at the document's top-level indentation and never deeper,
// so a nested key of the same name survives.
let nested = (cfg.piSettings as NSString).deletingLastPathComponent + "/nested-model.json"
try "{\n  \"model\": \"top/one\",\n  \"provider\": {\n    \"omlx\": {\n      \"model\": \"nested/two\"\n    }\n  }\n}\n"
    .write(toFile: nested, atomically: true, encoding: .utf8)
try ConfigFile.setJSONString("model", to: "top/three", in: nested)
let nestedAfter = try ConfigFile.read(nested)
SelfTest.check("the top-level key took the new value", nestedAfter.contains("\"model\": \"top/three\""))
SelfTest.check("the nested model key is untouched", nestedAfter.contains("\"model\": \"nested/two\""))
```

Beyond the checks shown above, the suite must also cover two paths the brief's list does not spell out: the **absent YAML key** insertion path (Task 6 depends on this — hermes reports `unset` before the write and configured after it), and the written file **keeping its original POSIX mode**, because a temp-file-and-rename write otherwise resets a `0600` config to the default.

Two further checks are required by the rules in Step 3: a **minified** JSON document (no line-start key to key off) must fail as `ConfigError.malformed` rather than being rewritten with a duplicate key; and an **empty** `{}` document must still take the insert path and must not throw.

- [ ] **Step 2: Run to verify it fails**

Run: `./.build/ProviderCostController --selftest`
Expected: FAIL — `ConfigFile` and `ToolModelRef` do not exist, so the build fails.

- [ ] **Step 3: Implement `ConfigFile` and `ToolModelRef`**

`setJSONString` replaces the value token of the matching **top-level** key and must not reformat, reorder, or lose any other byte. Two rules it must follow, both of which have a check in Step 1:

1. **Match the key at the document's top-level indentation, and never deeper.** A real config contains a nested key of the same name (`provider.omlx.model`), and a pattern that matches anywhere in the line would corrupt it. Note that pretty-printed JSON indents top-level keys too — the binding fixtures in this task use two spaces — so requiring literal column 0 is **wrong**: it misses the real top-level key and inserts a duplicate alongside it. Determine the indentation the document actually uses for its top-level keys and require exactly that, rejecting anything indented deeper. `setYAMLScalar` keeps literal column 0, which *is* correct for YAML. **Known limitation:** minified JSON, which has no indentation to key off, is not supported — it must fail as `ConfigError.malformed` rather than silently matching nothing and appending a duplicate key. Do **not** implement this by throwing whenever no top-level indent is found: an empty document (`{}`) has no keys to duplicate and must still take the insert path.
2. **Insert when the key is absent.** A fresh install may have no top-level `model` key at all; a silent no-op there would report success while changing nothing. Insert a new top-level entry immediately before the document's final closing brace, leaving every existing byte in place.

`setYAMLScalar` replaces a top-level `key: value` line, or appends `key: value` when absent — the same absent-key requirement, which is live for hermes because its fixture deliberately has no `model:` line. Both functions call `backup` then `atomicWrite` (temp file in the same directory, then `rename`), and both return the new contents. `atomicWrite` must **preserve the original file's POSIX permissions**: creating a temp file and renaming it over the original otherwise resets the file to the process default, silently loosening a user's `0600` config. `parse` splits on the first `/` and returns `nil` when there is no `/`.

- [ ] **Step 4: Run to verify it passes**

Run: `./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: all checks PASS, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ConfigFile.swift Sources/SelfTest.swift Tests/fixtures
git commit -m "feat: targeted config edit primitives with backup and atomic write"
```

---

### Task 4: pi adapter

**Files:**
- Create: `Sources/Tools.swift` (add the `ToolAdapter` struct and the pi adapter), `Tests/fixtures/pi-auth.json`, `Tests/fixtures/pi-models.json`, `Tests/fixtures/pi-models-store.json`
- Modify: `Sources/SelfTest.swift`

**Fixture contents — binding.** These filenames are already in `ToolPaths`' staging map, so use them exactly. Tasks 4 and 9 both assert against these values; do not change them to suit your implementation.

`Tests/fixtures/pi-auth.json` — the `access` value is load-bearing: Task 9 asserts that importing the key from pi returns exactly this string, so it must be present verbatim under `openrouter.access`.

```json
{
  "openrouter": { "type": "oauth", "access": "sk-or-v1-selftest-fixture-not-a-real-key", "refresh": "" },
  "openai": { "type": "api_key", "key": "not-a-real-key" },
  "opencode": { "type": "api_key", "key": "not-a-real-key" }
}
```

`Tests/fixtures/pi-models.json` — supplies the custom `ollama` provider and its model:

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://localhost:11434/v1",
      "api": "openai-completions",
      "models": [ { "id": "qwen3.8:latest" } ]
    }
  }
}
```

`Tests/fixtures/pi-models-store.json` — supplies the cached OpenRouter catalog with display names, which is where `models("openrouter")` gets `~anthropic/claude-fable-latest` from:

```json
{
  "openrouter": {
    "models": [
      { "id": "~anthropic/claude-fable-latest", "name": "Anthropic: Claude Fable Latest", "provider": "openrouter" },
      { "id": "deepseek/deepseek-v4.1-flash", "name": "DeepSeek: DeepSeek V4.1 Flash", "provider": "openrouter" }
    ]
  }
}
```

No real credentials in any of these; `not-a-real-key` and the `sk-or-v1-selftest-fixture-not-a-real-key` placeholder are the only key-shaped strings.

**Interfaces:**
- Consumes: `ConfigFile`, `ToolModelRef`, `ToolPaths` from Task 3.
- Produces: `struct ToolAdapter` with `id`, `displayName`, `detect() -> Bool`, `currentModel() throws -> ToolModelRef?`, `providers() throws -> [String]`, `models(_ provider: String) throws -> [(id: String, name: String)]`, `setModel(_ ref: ToolModelRef) throws`.
- Produces: `enum Tools { static func pi(_ paths: ToolPaths) -> ToolAdapter }`. Tasks 5–7 each add one more factory; Task 8 adds `all` and `detected`. Do not define `all` here.

- [ ] **Step 1: Write the failing tests**

```swift
let pi = Tools.pi(cfg)
SelfTest.check("pi detects", pi.detect())
SelfTest.check("pi reads current model",
    try pi.currentModel() == ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash"))
SelfTest.check("pi providers include authed and configured ones",
    Set(try pi.providers()).isSuperset(of: ["openrouter", "openai", "ollama"]))
SelfTest.check("pi model list carries display names",
    (try pi.models("openrouter")).contains { $0.id == "~anthropic/claude-fable-latest" })
SelfTest.check("pi model list falls back to configured models",
    (try pi.models("ollama")).contains { $0.id == "qwen3.8:latest" })
let piBefore = try ConfigFile.read(cfg.piSettings)
try pi.setModel(ToolModelRef(provider: "openai", model: "gpt-5.6-luna"))
SelfTest.check("pi wrote both keys",
    try pi.currentModel() == ToolModelRef(provider: "openai", model: "gpt-5.6-luna"))
SelfTest.check("pi preserved the rest of settings.json",
    (try ConfigFile.read(cfg.piSettings)).contains("\"defaultThinkingLevel\""))
```

- [ ] **Step 2: Run to verify it fails** — build error, `Tools` undefined.

- [ ] **Step 3: Implement the pi adapter**

`detect` is file-exists on `piSettings` or a `pi` binary on PATH. `currentModel` reads `defaultProvider` and `defaultModel`. `providers` is the union of keys in `piAuth`, `providers` in `piModels`, and keys in `piModelsStore`. `models` reads `piModelsStore[provider].models` (fields `id`, `name`) and merges `piModels.providers[provider].models` (field `id`). `setModel` writes both `defaultProvider` and `defaultModel` via two `setJSONString` calls.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Make the staged config unwritable and assert the write fails cleanly.** Review Focus #1.

`chmod 444` on the file itself is **not** sufficient: `rename(2)` only needs write permission on the *parent directory*, so the atomic write would still succeed and the test would pass for the wrong reason. Instead stage `pi-settings.json` inside its own subdirectory, `chmod 0555` that subdirectory, and restore `0755` afterwards.

Capture the bytes to compare against **immediately before the failing write**, in this step — not the `piBefore` variable from Step 1. Step 1 writes a new model into this same file, so the file's contents have legitimately changed by now and comparing against Step 1's bytes would assert something that cannot be true:

```swift
let readOnlyBefore = try ConfigFile.read(cfg.piSettings)
SelfTest.check("read-only config reports an error",
    (try? pi.setModel(ToolModelRef(provider: "x", model: "y"))) == nil)
SelfTest.check("read-only config is left byte-identical",
    try ConfigFile.read(cfg.piSettings) == readOnlyBefore)
```

- [ ] **Step 6: Commit**

```bash
git add Sources/Tools.swift Sources/SelfTest.swift Tests/fixtures
git commit -m "feat: pi adapter with catalog, provider discovery and safe writes"
```

---

### Task 5: opencode adapter

**Files:**
- Create: `Tests/fixtures/opencode-auth.json`
- Modify: `Sources/Tools.swift`, `Sources/SelfTest.swift`

All four adapters live in `Sources/Tools.swift`; there is no separate per-adapter file. If that file grows past roughly 250 lines by Task 8, report it as a concern rather than splitting it on your own initiative.

**Fixture content — binding.** `Tests/fixtures/opencode-auth.json` supplies the authenticated providers that `opencode.json`'s `provider` block does not list. `Tests/fixtures/opencode.json` (created by Task 3, and not to be modified) already carries `omlx` and `lmstudio` in its `provider` block, so this file only needs to add `openrouter`, which gives the provider union all three sources:

```json
{
  "openrouter": { "type": "api_key", "key": "not-a-real-key" }
}
```

No real credentials; `not-a-real-key` is the only key-shaped string.

**Interfaces:**
- Consumes: everything from Task 4.
- Produces: `Tools.opencode(_ paths: ToolPaths) -> ToolAdapter`.

- [ ] **Step 1: Write the failing tests**

```swift
let oc = Tools.opencode(cfg)
SelfTest.check("opencode detects", oc.detect())
SelfTest.check("opencode reads the nested model id",
    try oc.currentModel() == ToolModelRef(provider: "omlx",
        model: "Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"))
SelfTest.check("opencode providers union config and auth",
    Set(try oc.providers()).isSuperset(of: ["omlx", "lmstudio", "openrouter"]))
try oc.setModel(ToolModelRef(provider: "openrouter", model: "acme/opus-1"))
SelfTest.check("opencode wrote the model", try oc.currentModel() == ToolModelRef(provider: "openrouter", model: "acme/opus-1"))
SelfTest.check("opencode preserved its provider block",
    (try ConfigFile.read(cfg.opencodeConfig)).contains("@ai-sdk/openai-compatible"))
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the opencode adapter**

`detect` is file-exists on `opencodeConfig` or PATH. `currentModel` reads the top-level `model` and parses it. `providers` is the union of the config's `provider` keys and `opencodeAuth` keys. `models` returns the model ids already configured for that provider in the config, and an empty list otherwise, since the UI accepts free text. Do **not** call `OpenRouter` from this file — it does not exist until Task 10; Task 12 injects the catalog for provider `openrouter`. `setModel` writes `"provider/model"` to the top-level `model` key.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools.swift Sources/SelfTest.swift Tests/fixtures
git commit -m "feat: opencode adapter"
```

---

### Task 6: hermes adapter

**Files:**
- Modify: `Sources/Tools.swift`, `Sources/SelfTest.swift`
- Create: `Tests/fixtures/hermes.env`

**Interfaces:**
- Produces: `Tools.hermes(_ paths: ToolPaths) -> ToolAdapter`.

**Required refactor — do this before adding the hermes adapter.** `detectPi` and `detectOpencode` in `Sources/Tools.swift` are verbatim copies of each other, doc comment and `PATH` split loop included, and this task and Task 7 would each add another copy — four near-identical functions, so one bug fix would need four edits. Extract a single shared helper first:

`private func isExecutableOnPath(_ name: String) -> Bool`

which performs the `PATH` split and the `isExecutableFile` test, and make every `detect*` function read `fileExists(path) || isExecutableOnPath("<tool>")`. Update `detectPi` and `detectOpencode` to use it as part of this task. Do not change any adapter's observable behaviour: file existence stays the primary signal, because a Finder-launched app gets a minimal `PATH` and the binary lookup can miss an installed tool. The existing per-adapter detection checks are what prove behaviour is unchanged; no new check is required for the helper itself.

- [ ] **Step 1: Write the failing tests**

```swift
let he = Tools.hermes(cfg)
SelfTest.check("hermes detects from config.yaml", he.detect())
SelfTest.check("hermes reports no model when unset", try he.currentModel() == nil)
try he.setModel(ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash"))
SelfTest.check("hermes wrote a top-level model",
    try he.currentModel() == ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash"))
SelfTest.check("hermes kept the plugins block",
    (try ConfigFile.read(cfg.hermesConfig)).contains("orca-status"))
SelfTest.check("hermes providers include env-configured ones",
    Set(try he.providers()).isSuperset(of: ["openrouter", "synthetic"]))
SelfTest.check("a nested providers: section is not read as the top-level one", {
    let nestedYaml = (cfg.piSettings as NSString).deletingLastPathComponent + "/nested-providers.yaml"
    try "llm:\n  providers:\n    bogus:\n      model: x\n".write(toFile: nestedYaml, atomically: true, encoding: .utf8)
    var nestedPaths = cfg
    nestedPaths.hermesConfig = nestedYaml
    return !(try Tools.hermes(nestedPaths).providers()).contains("bogus")
}())
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the hermes adapter**

`Tests/fixtures/hermes.env` must carry two variables: `OPENROUTER_API_KEY=not-a-real-key`, and a second whose provider name is **neither in the curated list nor in the YAML** — use `SYNTHETIC_API_KEY=not-a-real-key`, giving the provider `synthetic`. The second is what makes the env-parsing check able to fail: `openrouter` is already in the curated list, so asserting only on it would pass even with the entire env-parsing block deleted. No real credentials.

`detect` is file-exists on `hermesConfig`. `currentModel` reads a top-level `model:` scalar if present, otherwise `nil`. `providers` is a curated list (`openrouter`, `openai`, `anthropic`, `google`, `nous`, `zai`, `kimi`, `deepseek`) unioned with any `providers:` keys in the YAML and with provider names implied by `*_API_KEY` names in `hermesEnv`. `setModel` calls `ConfigFile.setYAMLScalar("model", ...)`.

**The section-header match must require indent 0.** When locating the top-level `providers:` section, a header matched on the trimmed line is worse than useless: a `providers:` nested under some other top-level key (for example `llm:` → `providers:` → `bogus:`) is then accepted as the top-level section, and its child keys surface as provider names the config does not actually have. Require the header to begin at column 0 and let the existing deeper-indent guard handle everything beneath it. This is the rule the `nested-providers.yaml` check above pins.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools.swift Sources/SelfTest.swift Tests/fixtures
git commit -m "feat: hermes adapter with YAML scalar edits"
```

---

### Task 7: clawdbot adapter

**Files:**
- Modify: `Sources/Tools.swift`, `Sources/SelfTest.swift`
- Create: `Tests/fixtures/bin/clawdbot` (executable stub), `Tests/fixtures/clawdbot.json`

**Interfaces:**
- Produces: `Tools.clawdbot(_ paths: ToolPaths) -> ToolAdapter`.
- Produces: `Tools.clawdbot(_ paths: ToolPaths, candidates: [String]? = nil) -> ToolAdapter`. `candidates` defaults to `nil`, meaning the real search list; injecting a list is what makes the file-parse fallback reachable from a check, because otherwise the adapter resolves the stub and the fallback is dead code.
- Produces: `static func resolveClawdbotBinary(candidates: [String]) -> String?` on `enum Tools` — returns the first executable entry, otherwise `nil`. One list, not a preferred-plus-rest pair, so the adapter's search list and the check's list are the same shape. Pure, so it is testable without running anything.
- Produces: `static func parseClawdbotModel(_ stdout: String) -> ToolModelRef?` on `enum Tools` — turns `clawdbot config get agents.defaults.model` stdout into a ref, or `nil` when there is nothing to report. Pure, so it is testable against captured CLI output without spawning anything.

- [ ] **Step 1: Write the failing tests**

The stub reads `$1` and `$2`: for `models list` it prints a canned `{"count":1,"models":[{"key":"anthropic/claude-opus-4-5","name":"Claude Opus 4.5 (latest)","contextWindow":200000,"available":true}]}`; for `config get` it prints the object form `{"primary":"anthropic/claude-opus-4-5","fallbacks":["openai/gpt-4o"]}`; for `models set` it appends the argument to `$CLAWDBOT_STUB_LOG` and rewrites the fixture's `primary`. All three branches print to stdout only.

```swift
let cb = Tools.clawdbot(cfg)   // cfg.clawdbotBin points at the stub
SelfTest.check("clawdbot detects from its state dir", cb.detect())
SelfTest.check("clawdbot reads primary from the object form",
    try cb.currentModel() == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))
SelfTest.check("clawdbot model list parses the CLI json",
    (try cb.models("anthropic")).contains { $0.id == "anthropic/claude-opus-4-5" && $0.name == "Claude Opus 4.5 (latest)" })
let cbBefore = try ConfigFile.read(cfg.clawdbotConfig)
try cb.setModel(ToolModelRef(provider: "openrouter", model: "acme/opus-1"))
SelfTest.check("clawdbot delegated the write to its CLI",
    try ConfigFile.read(cfg.clawdbotConfig).contains("openrouter/acme/opus-1"))
SelfTest.check("clawdbot preserved fallbacks",             // Review Focus #2
    try ConfigFile.read(cfg.clawdbotConfig).contains("\"fallbacks\""))
SelfTest.check("clawdbot created a backup", FileManager.default.fileExists(atPath: cfg.clawdbotConfig + ".bak"))
```

Also stage a copy whose `agents.defaults.model` is a plain string, and assert it is read correctly.

**Binary resolution — required, because this is the one adapter that must run a binary.**

```swift
// An app launched from Finder gets a minimal PATH, so absolute candidates must be searched.
let stub = cfg.clawdbotBin
SelfTest.check("clawdbot binary resolves from the first candidate when executable",
    Tools.resolveClawdbotBinary(candidates: [stub, "/nonexistent/a"]) == stub)
SelfTest.check("clawdbot binary falls back past a non-executable candidate",
    Tools.resolveClawdbotBinary(candidates: ["/nonexistent/a", stub]) == stub)
SelfTest.check("clawdbot binary returns nil when nothing is executable",
    Tools.resolveClawdbotBinary(candidates: ["/nonexistent/a"]) == nil)

// The file-parse fallback is the path taken when no CLI can be launched — the read-only
// case the spec mandates. Without an injected list it is unreachable from a check, because
// the real search list resolves the stub.
var fallback = cfg
SelfTest.check("with no runnable CLI, the object form is read from the file",
    try Tools.clawdbot(fallback, candidates: ["/nonexistent/clawdbot"]).currentModel()
        == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))

let stringForm = (cfg.piSettings as NSString).deletingLastPathComponent + "/clawdbot-string.json"
try "{\n  \"agents\": {\n    \"defaults\": {\n      \"model\": \"anthropic/claude-opus-4-5\"\n    }\n  }\n}\n"
    .write(toFile: stringForm, atomically: true, encoding: .utf8)
fallback.clawdbotConfig = stringForm
SelfTest.check("with no runnable CLI, the string form is read from the file",
    try Tools.clawdbot(fallback, candidates: ["/nonexistent/clawdbot"]).currentModel()
        == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))

// "if the file parse also fails, report the error rather than hiding it" — so this must
// throw. `(try? …) == nil` would pass on a silent unset too and is not an acceptable check.
let broken = (cfg.piSettings as NSString).deletingLastPathComponent + "/clawdbot-broken.json"
try "{ not json".write(toFile: broken, atomically: true, encoding: .utf8)
fallback.clawdbotConfig = broken
var unreadableThrew = false
do { _ = try Tools.clawdbot(fallback, candidates: ["/nonexistent/clawdbot"]).currentModel() }
catch { unreadableThrew = true }
SelfTest.check("an unreadable config with no runnable CLI reports an error, not unset", unreadableThrew)

// An object without a `primary` string must read as unset, not as a garbage scalar ref.
SelfTest.check("clawdbot reports unset for an object with no primary",
    Tools.parseClawdbotModel("{\"fallbacks\": [\"openai/gpt-4o\"]}") == nil)
```

Each of those can fail, and together they pin all three branches: preferred wins, candidate fallback works, and a total miss returns `nil` so the adapter can degrade instead of launching something arbitrary.

**Reading the model — the CLI is the JSON5-safe reader.** `clawdbot.json` is JSON5, so `JSONSerialization` fails outright on a file that contains comments — with the exact error `Expecting property name enclosed in double quotes`. Verified against the real binary and a comment-laden file. These are verbatim CLI outputs captured from it:

```swift
SelfTest.check("clawdbot parses the object form from CLI stdout",
    Tools.parseClawdbotModel("{\n  \"primary\": \"anthropic/claude-opus-4-5\",\n  \"fallbacks\": [\n    \"openai/gpt-4o\"\n  ]\n}") == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))
SelfTest.check("clawdbot parses a bare scalar from CLI stdout",
    Tools.parseClawdbotModel("anthropic/claude-opus-4-5") == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))
SelfTest.check("clawdbot reports unset for the CLI's not-found message",
    Tools.parseClawdbotModel("Config path not found: agents.defaults.model") == nil)
SelfTest.check("clawdbot reports unset for empty CLI output",
    Tools.parseClawdbotModel("") == nil)
```

**End-to-end, on a config the file parser cannot read.** Write a comment-laden JSON5 document (`{ // a comment\n "agents": { "defaults": { "model": { "primary": "anthropic/claude-opus-4-5", "fallbacks": ["openai/gpt-4o"] } } } }`) into the staged temp root, point a copy of `ToolPaths` at it, and assert `currentModel()` still returns the anthropic ref. That check fails if the file parse is attempted first and its throw escapes, which is precisely the defect being fixed:

```swift
SelfTest.check("a comment-laden JSON5 config still reads through the CLI",
    try Tools.clawdbot(json5Paths).currentModel() == ToolModelRef(provider: "anthropic", model: "claude-opus-4-5"))
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the clawdbot adapter**

`detect` is the state directory existing or a **resolved** `clawdbot` binary — use the same search list the adapter uses, not a `PATH`-only lookup. A Finder-launched app with clawdbot installed at `/usr/local/bin` and no config directory must still report detected, because the adapter can in fact run it. `currentModel` resolves the binary, runs `clawdbot config get agents.defaults.model`, and passes stdout to `parseClawdbotModel`. The CLI is tried **first and is the authoritative reader**, because it is JSON5-safe and the file is JSON5: a direct `JSONSerialization` read of a commented config throws, and that throw must not be what the user sees. Fall back to the file parse only when resolution returns `nil`, handling both the object form (`agents.defaults.model.primary`) and the string form (`agents.defaults.model` as a scalar). If the file parse also fails, **throw** rather than reporting `nil`, so an unreadable config is reported and not hidden as unset. `parseClawdbotModel` must return `nil` for anything that is not a model reference — including an object with no `primary` string, which must not fall through to the scalar branch and produce a ref built from JSON punctuation. `models` runs `clawdbot models list --json` via `Process`, parses stdout only (stderr carries cert warnings), and returns `key`/`name`. `setModel` runs `clawdbot models set <qualified>` **and** performs `ConfigFile.backup` first; it never rewrites the JSON5 file itself. If the binary cannot be launched, `setModel` throws `ConfigError.write` with the reason, so the UI shows a read-only row.

**Binary lookup.** Build the candidate list as `paths.clawdbotBin`, then `/usr/local/bin/clawdbot`, `/opt/homebrew/bin/clawdbot`, then `~/.local/bin/clawdbot`, and only as a last resort scan `PATH`. Route every invocation through `resolveClawdbotBinary(preferred:candidates:)` rather than calling `Process` with a bare name, so the Finder-launch case works and so the resolution is testable on its own. Store the resolved path, and if resolution returns `nil`, `models` returns an empty list and `setModel` throws — never fall back to launching a bare `clawdbot`, which would produce a confusing launch failure instead of a clear one.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools.swift Sources/SelfTest.swift Tests/fixtures
git commit -m "feat: clawdbot adapter delegating writes to its JSON5-safe CLI"
```

---

### Task 8: Detection registry and unset handling

**Files:**
- Modify: `Sources/Tools.swift`, `Sources/SelfTest.swift`

**Interfaces:**
- Produces: `Tools.all(_ paths: ToolPaths) -> [ToolAdapter]` returning all four.
- Produces: `Tools.detected(_ adapters: [ToolAdapter]) -> [ToolAdapter]`, the pure filter, plus `Tools.detected(_ paths: ToolPaths) -> [ToolAdapter]` which is `detected(all(paths))`. Splitting the filter out makes it testable with synthetic adapters, which matters because **pi, opencode, and clawdbot** each fall back to `PATH` and are all installed on the reference machine — so a staged-absence check cannot work for those three. Hermes is the exception and is what makes the production overload testable: its `detect()` is file-existence only, with no `PATH` fallback, so pointing its config at a missing file genuinely makes it undetected on any machine. Calling `Tools.clawdbot(paths)` with its default candidate list is correct here.
- Produces: `enum ToolState { case missing, unset, configured(ToolModelRef) }` and `ToolAdapter.state() throws -> ToolState`.

- [ ] **Step 1: Write the failing tests**

```swift
// pi, opencode and clawdbot each fall back to PATH and are all installed on the reference
// machine, so for those three a staged-absence check cannot fail. Hermes is the exception:
// its detect() is file-existence only, with no PATH fallback, so an absent config file makes
// it genuinely undetected on any machine. That is also what covers the production overload
// `Tools.detected(_ paths:)`, which Tasks 11 and 12 actually call — without it, a wrong
// delegation there would ship unnoticed.
var headless = cfg
headless.hermesConfig = (cfg.piSettings as NSString).deletingLastPathComponent + "/no-such-hermes.yaml"
SelfTest.check("the production registry excludes a tool whose config is absent",
    !Tools.detected(headless).contains { $0.id == "hermes" })
SelfTest.check("the production registry still includes a tool whose config is present",
    Tools.detected(cfg).contains { $0.id == "hermes" })

// The pure filter, tested with synthetic adapters so the assertion does not depend on what
// happens to be installed on the machine running the suite.
let yes = ToolAdapter(id: "yes", displayName: "yes", detect: { true }, currentModel: { nil },
                      providers: { [] }, models: { _ in [] }, setModel: { _ in })
let no = ToolAdapter(id: "no", displayName: "no", detect: { false }, currentModel: { nil },
                     providers: { [] }, models: { _ in [] }, setModel: { _ in })
SelfTest.check("the registry filters out undetected adapters",
    Tools.detected([yes, no]).map(\.id) == ["yes"])
SelfTest.check("the registry keeps a detected adapter",
    Tools.detected([no, yes]).map(\.id) == ["yes"])
SelfTest.check("all four adapters are registered",
    Tools.all(cfg).map(\.id) == ["pi", "opencode", "hermes", "clawdbot"])
SelfTest.check("state reports missing for an undetected adapter",
    try no.state() == .missing)
SelfTest.check("state reports unset for a detected adapter with no model",
    try yes.state() == .unset)
SelfTest.check("a configured tool reports its ref",
    try Tools.pi(cfg).state() == .configured(ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash")))
SelfTest.check("hermes reports unset rather than throwing",
    try Tools.hermes(cfg).state() == .unset)

// An unreadable config must surface, not be quietly mapped to `.missing`.
let broken = ToolAdapter(id: "broken", displayName: "broken", detect: { true },
                         currentModel: { throw ConfigError.malformed("/nonexistent", "unreadable") },
                         providers: { [] }, models: { _ in [] }, setModel: { _ in })
var stateThrew = false
do { _ = try broken.state() } catch { stateThrew = true }
SelfTest.check("an unreadable config is reported, not mapped to missing", stateThrew)
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the registry and `state()`**

`state()` returns `.missing` when `detect()` is false, `.unset` when `currentModel()` is `nil`, and `.configured` otherwise. Errors from `currentModel()` throw rather than being mapped to `.missing`, so an unreadable config is reported instead of hidden. Add the `state()` method to the existing `ToolAdapter` struct in `Sources/Tools.swift` — an earlier task's doc comment already forward-references it, and this is the task that adds it.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools.swift Sources/SelfTest.swift
git commit -m "feat: tool detection registry with explicit unset state"
```

---

### Task 9: Keychain and pi key import

**Files:**
- Create: `Sources/Keychain.swift`
- Modify: `Sources/SelfTest.swift`

**Interfaces:**
- Produces: `enum Keychain` with `static let service`, `static func get(account: String) -> String?`, `static func set(_ value: String, account: String) throws`, `static func delete(account: String) throws`.

**`delete` throws, and tolerates `errSecItemNotFound`.** An earlier version of this brief declared `delete` with no error path, which the implementer correctly matched — but that means a failed removal reports success, and "I deleted my API key" silently leaving the secret in place is exactly the kind of thing a user cannot verify for themselves. So it throws. It must **not** throw when the account simply has no item: removing an already-removed key is a no-op, not an error, and treating `errSecItemNotFound` as a failure would make a second clear-key action fail spuriously.
- Produces: `static func importFromPi(_ paths: ToolPaths) -> String?` returning the OpenRouter credential from `piAuth` when one is present.

**`set` must upsert.** Verified against the real Keychain: `SecItemAdd` on an account that already has an item returns `-25299` (`errSecDuplicateItem`). So a plain `SecItemAdd` implementation fails the second time the user changes the API key — and a single leftover item from an interrupted run would fail this suite from then on. Delete-then-add or `SecItemUpdate`; either is fine, a failing re-set is not.

`Security` is already linked by `scripts/build.sh` (line 10), so this task needs **no build change**. Do not touch `scripts/build.sh`.

- [ ] **Step 1: Write the failing tests**

Use a test-only account so the real key is never touched. `Tests/fixtures/pi-auth.json` holds the literal placeholder `"access": "sk-or-v1-selftest-fixture-not-a-real-key"`, so the import assertion has a real expected value.

The Keychain is the one dependency here that is not a file, so the "never touch a real user path" rule reads as: **use only the `selftest` account, never the `openrouter` account the app itself writes**, and delete it when done. Verified by probe that a terminal-run binary can add, read, and delete a generic-password item with no prompt and no hang, so these checks are safe to run unattended.

```swift
var setFailed = false
do { try Keychain.set("test-value-not-a-real-key", account: "selftest") } catch { setFailed = true }
SelfTest.check("keychain set succeeds", !setFailed)
SelfTest.check("keychain round-trips", Keychain.get(account: "selftest") == "test-value-not-a-real-key")

// Setting twice must overwrite, not fail: SecItemAdd on an existing item returns
// errSecDuplicateItem, and a leftover item from an interrupted run must not wedge the suite.
var reSetFailed = false
do { try Keychain.set("second-value-not-a-real-key", account: "selftest") } catch { reSetFailed = true }
SelfTest.check("keychain set overwrites an existing value",
    !reSetFailed && Keychain.get(account: "selftest") == "second-value-not-a-real-key")

var deleteThrew = false
do { try Keychain.delete(account: "selftest") } catch { deleteThrew = true }
SelfTest.check("keychain delete succeeds", !deleteThrew)
SelfTest.check("keychain delete works", Keychain.get(account: "selftest") == nil)

// Removing a key that is already gone is a no-op, not an error — otherwise a second
// clear-key action would fail spuriously with nothing to remove.
var absentDeleteThrew = false
do { try Keychain.delete(account: "selftest") } catch { absentDeleteThrew = true }
SelfTest.check("deleting an absent key does not throw", !absentDeleteThrew)

SelfTest.check("import finds the pi openrouter credential",
    Keychain.importFromPi(cfg) == "sk-or-v1-selftest-fixture-not-a-real-key")

var noAuth = cfg
noAuth.piAuth = (cfg.piSettings as NSString).deletingLastPathComponent + "/no-such-auth.json"
SelfTest.check("import returns nil when the file is absent",
    Keychain.importFromPi(noAuth) == nil)
```

This check must compare against an expected value. A check written as `<condition> || true` can never fail and is a defect, not a test. The fixture holds a placeholder, never a real key.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement `Keychain`**

Generic password items via `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` with `kSecClassGenericPassword`. `importFromPi` reads `piAuth` as JSON and returns `openrouter.access` or `openrouter.key`. Never print the value.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/Keychain.swift Sources/SelfTest.swift
git commit -m "feat: keychain storage and one-click import of the existing pi key"
```

---

### Task 10: OpenRouter client and catalog cache

**Files:**
- Create: `Sources/OpenRouter.swift`
- Modify: `Sources/SelfTest.swift`

**Interfaces:**
- Produces: `struct Credits: Equatable { let totalCredits: Double; let totalUsage: Double; var remaining: Double }`.
- Produces: `enum OpenRouterError: Error { case badStatus(Int), notJSON, missingField(String) }`.
- Produces: `enum OpenRouter` with `static func parseCredits(_ data: Data) throws -> Credits`, `static func credits(apiKey: String) async throws -> Credits`, `static func models() async throws -> [(id: String, name: String)]`, `static func parseCatalog(_ data: Data) throws -> [(id: String, name: String)]`, `static func loadCachedCatalog(from path: String = OpenRouter.catalogPath) throws -> [(id: String, name: String)]?`, `static let catalogPath: String`.
- `catalogPath` is `~/Library/Application Support/ProviderCostController/models-cache.json`, alongside the settings file from Task 11. It is a real user path, so `loadCachedCatalog` takes a `path` parameter defaulting to it — the same injection pattern as `AppConfig` — because otherwise the 24-hour cache rule would be untestable without reading the user's actual cache.
- **No check in this task may perform network I/O.** `credits(apiKey:)` and `models()` are network calls; the suite must run offline and must not need a key. Their testable seam is the pure `parseCredits` / `parseCatalog`, and the cache checks below, which use temp files.

- [ ] **Step 1: Write the failing tests**

The parse function is pure, so it is the testable seam. Cases: valid body; a body with `total_credits` absent; an HTML error page; and a body with string-typed numbers.

```swift
SelfTest.check("credits parse", try OpenRouter.parseCredits(Data(#"{"data":{"total_credits":344.11,"total_usage":327.007530314}}"#.utf8)).remaining.rounded(toPlaces: 2) == 17.10)
SelfTest.check("missing total_usage is an error, not a zero", (try? OpenRouter.parseCredits(Data(#"{"data":{"total_credits":1}}"#.utf8))) == nil)
SelfTest.check("html error page is an error", (try? OpenRouter.parseCredits(Data("<html>502</html>".utf8))) == nil)
SelfTest.check("a non-JSON catalog is an error, not a crash", (try? OpenRouter.parseCatalog(Data("<html>".utf8))) == nil)
SelfTest.check("a catalog without names is an error", (try? OpenRouter.parseCatalog(Data(#"{"data":[{"id":"x"}]}"#.utf8))) == nil)
```

The 24-hour cache rule needs its own checks, because a cache that always returns `nil` or always serves stale data is a silent bug: the app would either refetch on every launch or never notice a price change. Use an injected temp path, and assert the absence of throwing as well as the absence of a value — `(try? …) == nil` alone cannot tell "returned nil" from "threw":

```swift
let cachePath = (cfg.piSettings as NSString).deletingLastPathComponent + "/models-cache.json"
var missingThrew = false
var missingResult: [(id: String, name: String)]? = [(id: "sentinel", name: "sentinel")]
do { missingResult = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { missingThrew = true }
SelfTest.check("a missing catalog cache returns nil rather than throwing",
    !missingThrew && missingResult == nil)

let stale = "{\"fetchedAt\": \"2001-01-01T00:00:00Z\", \"models\": [{\"id\": \"a/b\", \"name\": \"A\"}]}"
try stale.write(toFile: cachePath, atomically: true, encoding: .utf8)
var staleThrew = false
var staleResult: [(id: String, name: String)]? = nil
do { staleResult = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { staleThrew = true }
SelfTest.check("a catalog older than 24 hours is not served",
    !staleThrew && staleResult == nil)

let fresh = "{\"fetchedAt\": \"\(ISO8601DateFormatter().string(from: Date()))\", \"models\": [{\"id\": \"a/b\", \"name\": \"A\"}]}"
try fresh.write(toFile: cachePath, atomically: true, encoding: .utf8)
var freshResult: [(id: String, name: String)]? = nil
do { freshResult = try OpenRouter.loadCachedCatalog(from: cachePath) } catch { freshResult = nil }
SelfTest.check("a catalog fresher than 24 hours is served", (freshResult?.count ?? 0) == 1)
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the client**

`credits` performs `GET https://openrouter.ai/api/v1/credits` with the bearer key, checks the status code, and calls `parseCredits`. `parseCredits` decodes `data.total_credits` and `data.total_usage` as numbers and throws `missingField` if either is absent — a missing field must never be read as zero. `parseCatalog` decodes `data[]` entries and throws unless every entry has both `id` and `name`. `models` fetches `https://openrouter.ai/api/v1/models`, writes the parsed entries to `catalogPath` with a `fetchedAt` timestamp, and returns the cache without a network call when it is younger than 24 hours. `loadCachedCatalog(from:)` returns `nil` when the cache file is absent or its `fetchedAt` is more than 24 hours old, and a parse failure must surface as a thrown error rather than a silent empty list — replacing a corrupt cache by refetching is `models`' business, not this function's. Add `Double.rounded(toPlaces:)` as a small helper in this file.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenRouter.swift Sources/SelfTest.swift
git commit -m "feat: openrouter credits client with cached model catalog"
```

---

### Task 11: Settings model, menu bar presentation, and balance-alert decisions

**Files:**
- Create: `Sources/AppConfig.swift`, `Sources/UI.swift`
- Modify: `Sources/SelfTest.swift`

**Interfaces:**
- Produces: `struct AppConfig: Codable` with `refreshMinutes: Int = 10`, `launchAtLogin: Bool = false`, `hiddenTools: [String] = []`, `binaryPathOverrides: [String: String] = [:]`, `showMoneyInMenuBar: Bool = true`, `showIconInMenuBar: Bool = true`, `notifyBelowEnabled: Bool = false`, `notifyBelowAmount: Double = 5.0`, `static let path: String`, `static func load(from path: String = AppConfig.path) -> AppConfig`, `func save(to path: String = AppConfig.path) throws`. The path parameter is what keeps the selftest off the real settings file.
- Produces: `enum MenuBarPresentation` with `static func of(showMoney: Bool, showIcon: Bool, balance: Double?, error: Bool) -> (text: String?, symbol: String?)`, which decides what the status item renders.
- Produces: `enum BalanceAlert` with `static func shouldNotify(previous: Double?, current: Double?, threshold: Double, enabled: Bool, authorized: Bool) -> Bool`, which decides whether to raise a low-balance notification.
- Does **not** produce `AppState` or `PopoverView` — Task 12 owns those and consumes these two functions.

These two functions are pure, and that is the point: they encode the two behaviours that cannot be observed programmatically here (what the menu bar renders, and whether a notification should fire), so they are the parts that can actually be tested.

- [ ] **Step 1: Write the failing tests**

```swift
let root = (cfg.piSettings as NSString).deletingLastPathComponent
let settingsPath = root + "/app-config.json"
SelfTest.check("app settings round-trip", { var c = AppConfig.load(from: settingsPath); c.refreshMinutes = 42; try c.save(to: settingsPath); return AppConfig.load(from: settingsPath).refreshMinutes == 42 }())
SelfTest.check("the menu bar and alert fields round-trip", {
    var c = AppConfig.load(from: settingsPath)
    c.showMoneyInMenuBar = false; c.showIconInMenuBar = false
    c.notifyBelowEnabled = true; c.notifyBelowAmount = 12.5
    try c.save(to: settingsPath)
    let r = AppConfig.load(from: settingsPath)
    return !r.showMoneyInMenuBar && !r.showIconInMenuBar && r.notifyBelowEnabled && r.notifyBelowAmount == 12.5
}())
SelfTest.check("a corrupt settings file falls back to defaults", { try? "not json".write(toFile: settingsPath, atomically: true, encoding: .utf8); return AppConfig.load(from: settingsPath).refreshMinutes == 10 }())
SelfTest.check("an older settings file keeps its values and gains the new defaults", {
    try? "{\"refreshMinutes\": 33}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
    let c = AppConfig.load(from: settingsPath)
    return c.refreshMinutes == 33 && c.showMoneyInMenuBar && c.showIconInMenuBar && !c.notifyBelowEnabled
}())
SelfTest.check("defaults show the money and icon and leave alerts off", {
    let c = AppConfig.load(from: root + "/config-that-does-not-exist.json")
    return c.showMoneyInMenuBar && c.showIconInMenuBar && !c.notifyBelowEnabled
}())
SelfTest.check("the selftest never targets the real settings path", settingsPath != AppConfig.path)

// The status item must never be left with nothing to render, or it cannot be clicked.
SelfTest.check("money and icon both on renders both", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: false) == (text: "$17.10", symbol: "dollarsign.circle"))
SelfTest.check("money hidden renders the icon alone", MenuBarPresentation.of(showMoney: false, showIcon: true, balance: 17.1, error: false) == (text: nil, symbol: "dollarsign.circle"))
SelfTest.check("icon hidden renders the money alone", MenuBarPresentation.of(showMoney: true, showIcon: false, balance: 17.1, error: false) == (text: "$17.10", symbol: nil))
SelfTest.check("both hidden still renders something clickable", { let p = MenuBarPresentation.of(showMoney: false, showIcon: false, balance: 17.1, error: false); return p.text != nil || p.symbol != nil }())
SelfTest.check("an error renders the em dash", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: 17.1, error: true) == (text: "—", symbol: "dollarsign.circle"))
SelfTest.check("a balance that was never fetched renders no money text", MenuBarPresentation.of(showMoney: true, showIcon: true, balance: nil, error: false) == (text: nil, symbol: "dollarsign.circle"))

// Alerts fire on a crossing, never on a state: the app refetches every 10 minutes.
SelfTest.check("no alert when the feature is off", !BalanceAlert.shouldNotify(previous: 20, current: 3, threshold: 5, enabled: false, authorized: true))
SelfTest.check("no alert when permission was refused", !BalanceAlert.shouldNotify(previous: 20, current: 3, threshold: 5, enabled: true, authorized: false))
SelfTest.check("no alert at launch when already below the threshold", !BalanceAlert.shouldNotify(previous: nil, current: 3, threshold: 5, enabled: true, authorized: true))
SelfTest.check("no alert when the fetch failed", !BalanceAlert.shouldNotify(previous: 20, current: nil, threshold: 5, enabled: true, authorized: true))
SelfTest.check("no alert while already below", !BalanceAlert.shouldNotify(previous: 3, current: 2, threshold: 5, enabled: true, authorized: true))
SelfTest.check("no alert when both readings are above", !BalanceAlert.shouldNotify(previous: 20, current: 19, threshold: 5, enabled: true, authorized: true))
SelfTest.check("an alert on the crossing itself", BalanceAlert.shouldNotify(previous: 20, current: 3, threshold: 5, enabled: true, authorized: true))
SelfTest.check("exactly at the threshold is not below it", !BalanceAlert.shouldNotify(previous: 20, current: 5, threshold: 5, enabled: true, authorized: true))
SelfTest.check("one cent under the threshold alerts", BalanceAlert.shouldNotify(previous: 20, current: 4.99, threshold: 5, enabled: true, authorized: true))
```

Every selftest write must go to the temp directory. The selftest must never write to `~/.pi`, `~/.config`, `~/.hermes`, `~/.clawdbot`, or `~/Library`.

- [ ] **Step 2: Run to verify it fails** — build failure, `AppConfig` undefined.

- [ ] **Step 3: Implement `AppConfig` in `Sources/AppConfig.swift`**

Load returns defaults for every field when the file is absent or undecodable, and `load` must never throw. Save writes pretty-printed JSON.

**Decode field by field — this is the whole forward-compatibility requirement.** `AppConfig` is declared `Codable`, but a *synthesised* `init(from:)` throws when any key is missing. That would mean an older settings file fails to decode as a whole, `load` falls back to defaults, and every setting the file *did* contain is silently reset — the exact failure Review Focus #6 exists to prevent, and one that will really happen because this app owns this file and its schema is growing. So implement `init(from:)` with `decodeIfPresent(…​) ?? default` for **every** field, filling only what is absent. The brief's `an older settings file keeps its values and gains the new defaults` check is what pins this: it writes `{"refreshMinutes": 33}` and requires `refreshMinutes == 33` *and* the new fields at their defaults. Do not satisfy it by catching a decode failure, which loses the values.

- [ ] **Step 4: Implement `MenuBarPresentation` and `BalanceAlert` in `Sources/UI.swift`**

`MenuBarPresentation.of` formats the balance as `String(format: "$%.2f", …)`. Its rules, in order:

1. `symbol` is `"dollarsign.circle"` when `showIcon` is true, and `nil` when it is false — **unless** `showMoney` is also false, in which case `symbol` is `"dollarsign.circle"` regardless. A status item with neither text nor image has nothing to click, which would leave the app running but unreachable, so the last-possible-toggle case must still render.
2. `text` is `nil` when `showMoney` is false; `"—"` when `error` is true; `nil` when the balance has never been fetched; otherwise the formatted balance.
   A never-fetched balance must render nothing rather than `$0.00`, which would be a lie about the account.

`BalanceAlert.shouldNotify` returns true only when `enabled` **and** `authorized` **and** `previous` is non-nil and at or above `threshold` **and** `current` is non-nil and strictly below `threshold`. Note the consequences deliberately: a balance already below the threshold at launch does not alert, because nothing was crossed, and a failed fetch (`current == nil`) cannot alert. Do not "helpfully" fire on the first below-threshold reading; that would alert every ten minutes and is the exact spam this rule exists to prevent.

- [ ] **Step 5: Run to verify it passes.**

- [ ] **Step 6: Commit**

```bash
git add Sources/AppConfig.swift Sources/UI.swift Sources/SelfTest.swift
git commit -m "feat: settings model, menu bar presentation and balance-alert decisions"
```

---

### Task 12: Popover UI, refresh timer, launch at login, and alert delivery

**Files:**
- Modify: `Sources/UI.swift`, `Sources/main.swift`, `Sources/Tools.swift` (wire the catalog into `models`), `Sources/SelfTest.swift`, `scripts/build.sh`

**Interfaces:**
- Consumes: `AppConfig`, `MenuBarPresentation`, `BalanceAlert`, `Tools.detected`, `OpenRouter`, `Keychain`.
- Produces: `final class AppState: ObservableObject` with `@Published var remaining: Double?`, `lastUpdated: Date?`, `errorText: String?`, `rows: [ToolRow]`, `func refresh() async`, `func setModel(_ ref: ToolModelRef, for adapterID: String)`.
- Produces: `struct ToolRow { let id: String; let displayName: String; let state: ToolState; let providers: [String]; let writable: Bool }`.
- Produces: `struct PopoverView: View { @ObservedObject var state: AppState }`.

**Three requirements specific to this task.**

1. **`AppState` is `@MainActor`.** Its `@Published` properties are mutated from a timer callback and from `URLSession` completions, neither of which runs on the main thread. Mutating observable state off the main thread makes SwiftUI updates undefined and can crash; annotate the class `@MainActor` (or hop explicitly) and keep every mutation of `remaining` / `lastUpdated` / `errorText` / `rows` on the main actor. This is the most likely real defect in this task.
2. **`SMAppService.mainApp.register()` throws when the process is not a bundled app.** Running `./.build/ProviderCostController` directly is exactly that case, so the launch-at-login toggle must surface the failure rather than crash or silently do nothing — and the same applies to `unregister()`. The real path is the `.app` built by `scripts/build-app.sh`; verify the toggle there, and expect the direct-binary run to report an error rather than pretend to succeed.
3. **This task adds no new automated checks, and must not invent one.** The logic worth asserting — the menu bar presentation rules and the balance-crossing rule — was factored into pure functions in Task 11 precisely because that part is testable, and it is already covered. A check added here could only assert something about a view or a notification, which the suite cannot meaningfully observe, so it would necessarily be a check that cannot fail. The regression bar for this task is that the existing suite still passes, plus the manual verification below. Do not weaken or delete an existing check to accommodate the UI.

- [ ] **Step 1: Add the notification framework to the build**

`scripts/build.sh` must link `-framework UserNotifications`, because `UserNotifications` is not currently in its framework list and the build will fail without it. Keep the existing flags and target unchanged.

- [ ] **Step 2: Implement `AppState`, `PopoverView`, and wire `main.swift`**

One scrolling `PopoverView`: header (`$17.10`, fetched-at time, Refresh button), one `ToolRow` per detected tool showing `name — provider/model` or `unset` with a Change… control, and a collapsed Settings disclosure holding:

- the API key field with Test key,
- the refresh interval field,
- a **Menu bar** group: a show-balance checkbox and a show-icon checkbox, with a line of explanatory text stating that the icon stays visible when both are cleared, because the item must remain clickable,
- an **Alerts** group: an enable-low-balance-alert checkbox and a threshold amount field, plus the current OS permission state so a user can tell a blocked alert from a broken one,
- a launch-at-login checkbox,
- the tool path overrides.

The status item renders whatever `MenuBarPresentation.of` returns for the current state — never a hand-rolled `$X.YZ`/`—` branch inside the view. On a fetch failure set `errorText` and keep `remaining` and `lastUpdated` so the popover can show the last known balance with its age. The refresh timer runs every `refreshMinutes`, plus once at launch. Launch at login uses `SMAppService.mainApp.register()`/`unregister()`, driven by the checkbox.

**Catalog wiring.** `ToolAdapter.models` is synchronous and `OpenRouter.models()` is async, so they cannot be connected directly. At each refresh, fetch the catalog once asynchronously into a module-level cache; each adapter's `models` closure reads that cache synchronously and falls back to the tool's own configured models when the cache is empty. A failed catalog fetch must never fail the whole refresh.

- [ ] **Step 3: Wire balance-alert delivery**

`AppState` keeps the previous successful balance reading. On each successful fetch, compute `BalanceAlert.shouldNotify(previous:current:threshold:enabled:authorized:)`; when it returns true, post a `UNNotificationRequest` with the balance and the threshold, then update the stored previous reading. Request authorization once, when the user first enables the alert, and store the resulting state so the settings panel can display it. A refused permission must never re-prompt and must never fail the refresh.

Notification display cannot be asserted from the suite, so keep the decision in `BalanceAlert` (already covered in Task 11) and keep the delivery call as thin as possible: resolve the decision, post, update state. Do not add a second decision path in the view or the timer.

- [ ] **Step 4: Run to verify it passes, then verify by hand**

Run: `./scripts/build.sh && ./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: every check PASS, `exit=0`, and zero compiler warnings.
Run: `./scripts/build-app.sh && open ProviderCostController.app`
Expected: the menu bar shows the real balance (near `$17.10` at time of writing); opening the popover lists pi and opencode as configured, hermes and clawdbot as unset; toggling each menu bar checkbox re-renders the item and clearing both leaves the icon visible; changing a model updates that tool's file and its row. Confirm `~/.pi/agent/settings.json` and `~/.config/opencode/opencode.json` still have their original key order.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI.swift Sources/main.swift Sources/Tools.swift Sources/SelfTest.swift scripts/build.sh
git commit -m "feat: popover UI, refresh timer, launch at login, and balance-alert delivery"
```

---
### Task 13: README and final verification

**Files:**
- Create: `README.md`
- Modify: `Sources/UI.swift`, `scripts/build-app.sh` only if the smoke test exposes a defect

- [ ] **Step 1: Write `README.md`**

Cover: what it does, the four supported tools and the exact file each one writes, the build command and the CLT-only rationale, the `--selftest` and `--probe` flags, the Keychain service name and how to remove the key, the settings file path, launch at login, the two menu bar toggles (and that the icon stays visible when both are off, so the item remains clickable), the opt-in low-balance alert and how to change or disable its threshold, and an explicit list of what is not implemented (per-model 30-day stats, codex/claude/aider/droid/gptme adapters, writing the key into other tools' configs).

- [ ] **Step 2: Run the full suite**

Run: `./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: every check PASS, `exit=0`.
Run: `./.build/ProviderCostController --probe`
Expected: all four facts `true`.
Run: `./scripts/build-app.sh && open ProviderCostController.app`
Expected: launches, balance correct, tools listed.

- [ ] **Step 3: Verify no secrets leaked into the repo**

Run: `git grep -nE "sk-or-v1|apiKey" -- . ':!Tests/fixtures'`
Expected: no real key, and no key material in any committed fixture.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README with supported tools, flags, and known limitations"
```

---

## Self-Review

**Spec coverage:** Menu bar balance → Tasks 1, 10, 12. Settings for the API key → Tasks 9, 12. Tool detection and per-tool current model → Tasks 4–8. Model/provider selection writing to config → Tasks 3–7, 12. App settings file → Task 11. Menu bar presentation rules, including the both-toggles-off case and the never-fetched balance → Task 11. Balance-alert crossing rule → Task 11; its delivery and the permission state → Task 12. Launch at login → Task 12. Error handling section → Tasks 4 (read-only), 8 (unreadable config), 10 (bad responses), 12 (title falls back to `—`, last-known balance with age). Verification section → Tasks 2–12 build it incrementally, Task 13 runs it whole. Non-goals → nothing implements them; Task 13's README states them. Deferred items have no task, by design.

**Step scan:** Every step names either an exact assertion or an exact signature. The two places carrying more than a signature are `ConfigFile`'s targeted-edit rules and `parseCredits`' missing-field rule, both of which the tests alone do not disambiguate.

**Type consistency:** `ToolModelRef`, `ToolPaths`, `ToolAdapter`, `ToolState`, `ConfigError`, `Credits`, and `AppConfig` are named identically in every task that uses them. `tools` in Task 4 is the adapter family, `ToolRow` is the UI projection — distinct names for distinct things.

**Review Focus:** #1 → Task 4 step 5. #2 → Task 7 step 1. #3 → Task 3 step 1. #4 → Task 3 step 1 (`.bak` asserted against the pre-write bytes). #5 → Task 10 step 1 plus Task 12 step 4. #6 → Task 11 step 1.

**Proportion:** The plan is longer than the spec because it carries the interfaces the spec leaves open — path injection, the four adapter factories, and the parse seam. No task contains a full function body except where the tests cannot determine the algorithm.
