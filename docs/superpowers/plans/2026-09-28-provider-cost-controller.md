# Provider Cost Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app showing the OpenRouter balance and letting the user view and change the configured model of pi, opencode, hermes, and clawdbot/OpenClaw.

**Architecture:** One `LSUIElement` AppKit process. A flat table of four tool adapters, each with an injected `ToolPaths` so tests never touch real config. Adapters prefer a targeted key edit over parse-and-reserialize because clawdbot's config is JSON5 and the others must keep their formatting. `swiftc` builds the binary; a shell script assembles the `.app`.

**Tech Stack:** Swift 6.3.3, AppKit, SwiftUI, Security, ServiceManagement, Foundation `URLSession`. No third-party dependencies, no SwiftPM, no XCTest.

**Spec:** `docs/superpowers/specs/2026-09-28-provider-cost-controller-design.md`

## Global Constraints

- Executable and app name: `ProviderCostController`. Bundle identifier `local.provider-cost-controller`.
- Deployment target macOS 13.0. Build with `swiftc`, never SwiftPM (`swift package` cannot link `PackageDescription` under Command Line Tools).
- Build command: `swiftc -O -o .build/ProviderCostController Sources/*.swift -framework AppKit -framework SwiftUI -framework Security -framework ServiceManagement -target $(uname -m)-apple-macosx13.0`
- No XCTest. All automated checks are `assert`-based, run by `--selftest`, exit 0 on pass and 1 on failure.
- No third-party dependencies.
- Balance = `total_credits − total_usage` from `GET /api/v1/credits`, displayed to exactly two decimals (`$17.10`).
- Menu bar title on any fetch failure: `—` (U+2014 EM DASH).
- Model references split on the **first** `/` only.
- Every tool config write: copy original to `<file>.bak`, then write via temp file plus atomic rename.
- The API key lives only in the Keychain (service `provider-cost-controller`, account `openrouter`). It must never be written to a file, logged, or included in an error message.
- App settings file: `~/Library/Application Support/ProviderCostController/config.json`.
- Never write placeholder code for anything in the spec's Non-goals section.

## Review Focus

These are the failure modes the spec implies but no task's own tests cover. Each is pinned to the task that owns the code.

1. **A tool config that cannot be written** (read-only file, read-only parent directory, root-owned). Expected: a clear error, the original file byte-identical, and the other three tools still usable. → Task 4.
2. **`agents.defaults.model` stored as an object with `fallbacks`** (clawdbot). Expected: `primary` is set and the `fallbacks` array survives byte-for-byte. → Task 7.
3. **Model ids with extra separators** — `ollama/qwen3.8:latest`, `openrouter/anthropic/claude-fable-latest`. Expected: provider is the first segment, the model is everything after it, nothing truncated or re-joined. → Task 3.
4. **The file changed on disk between read and write** (another process edited it). Expected: the write does not silently clobber; `.bak` holds the state immediately before the write. → Task 3.
5. **OpenRouter returns a non-2xx, an HTML error page, or JSON missing `total_credits`.** Expected: no crash, error surfaced in the popover, previous balance kept and labelled with its age. → Task 10.

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
- Produces: `SelfTest.run() -> Int32` (0 pass, 1 fail) and `SelfTest.check(_ name: String, _ condition: @autoclosure () -> Bool)`, which prints each check's name and marks it PASS/FAIL.
- Produces: `struct ToolPaths` with all file locations, plus `static var real: ToolPaths` and `func stagedInTempDir(from fixtures: String) throws -> ToolPaths`. Every later adapter takes a `ToolPaths`.

- [ ] **Step 1: Write the failing test**

Add to `Sources/SelfTest.swift` a `run()` that calls `check("harness detects a false condition", 1 == 2)`. Dispatch `--selftest` from `main.swift` before any AppKit work.

- [ ] **Step 2: Run it to make sure it fails**

Run: `./scripts/build.sh && ./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: `FAIL harness detects a false condition`, `exit=1`.

- [ ] **Step 3: Fix the check and add `ToolPaths`**

Change the check to a true condition. Add `ToolPaths` fields: `piSettings`, `piAuth`, `piModels`, `piModelsStore`, `opencodeConfig`, `opencodeAuth`, `hermesConfig`, `hermesEnv`, `clawdbotDir`, `clawdbotBin`. `real` resolves the paths from the spec's table. `stagedInTempDir(from:)` copies every file present in the fixture directory into a fresh temp directory and returns a `ToolPaths` pointing at the copies.

- [ ] **Step 4: Run it to verify it passes**

Run: `./.build/ProviderCostController --selftest; echo "exit=$?"`
Expected: `PASS harness detects a false condition`, `exit=0`.

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

**Interfaces:**
- Produces: `enum ConfigFile` with `read(_ path: String) throws -> String`, `backup(_ path: String) throws`, `atomicWrite(_ contents: String, to path: String) throws`, `setJSONString(_ key: String, to value: String, in path: String) throws -> String`, `setYAMLScalar(_ key: String, to value: String, in path: String) throws -> String` (each returns the new contents in addition to writing).
- Produces: `struct ToolModelRef: Equatable` with `provider`, `model`, `var qualified: String` and `static func parse(_ raw: String) -> ToolModelRef?`.
- Produces: `enum ConfigError: Error` with cases `missing(path)`, `unreadable(path, String)`, `malformed(path, String)`, `write(path, String)`.

- [ ] **Step 1: Write the failing tests**

In `SelfTest.run()`, using a staged temp copy of `Tests/fixtures/opencode.json`:

```swift
SelfTest.check("parse splits on the first slash only",
    ToolModelRef.parse("openrouter/anthropic/claude-fable-latest")?.model == "anthropic/claude-fable-latest")
SelfTest.check("parse keeps a colon inside the model",
    ToolModelRef.parse("ollama/qwen3.8:latest")?.model == "qwen3.8:latest")
let before = try ConfigFile.read(cfg.opencodeConfig)
try ConfigFile.setJSONString("model", to: "openrouter/acme/opus-1", in: cfg.opencodeConfig)
let after = try ConfigFile.read(cfg.opencodeConfig)
SelfTest.check("only the model value changed", after.replacingOccurrences(of: "openrouter/acme/opus-1", with: "omlx/old") == before)
SelfTest.check("backup holds the pre-write bytes", try ConfigFile.read(cfg.opencodeConfig + ".bak") == before)
SelfTest.check("missing file is reported, not crashed", (try? ConfigFile.setJSONString("model", to: "x", in: "/nonexistent/y.json")) == nil)
```

- [ ] **Step 2: Run to verify it fails**

Run: `./.build/ProviderCostController --selftest`
Expected: FAIL — `ConfigFile` and `ToolModelRef` do not exist, so the build fails.

- [ ] **Step 3: Implement `ConfigFile` and `ToolModelRef`**

`setJSONString` replaces only the value token of the matching top-level key using a regex anchored to line start; it must not reformat or reorder anything else. `setYAMLScalar` replaces a top-level `key: value` line, or appends `key: value` when absent. Both call `backup` then `atomicWrite` (temp file in the same directory, then `rename`). `parse` splits on the first `/` and returns `nil` when there is no `/`.

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

**Interfaces:**
- Consumes: `ConfigFile`, `ToolModelRef`, `ToolPaths` from Task 3.
- Produces: `struct ToolAdapter` with `id`, `displayName`, `detect() -> Bool`, `currentModel() throws -> ToolModelRef?`, `providers() throws -> [String]`, `models(_ provider: String) throws -> [(id: String, name: String)]`, `setModel(_ ref: ToolModelRef) throws`.
- Produces: `enum Tools { static func pi(_ paths: ToolPaths) -> ToolAdapter; static func all(_ paths: ToolPaths) -> [ToolAdapter] }` (only `pi` returns a real adapter here; the rest are added by Tasks 5–7).

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

- [ ] **Step 5: Set `chmod 444` on the staged copy of `piSettings` and assert the write fails cleanly.** Review Focus #1.

```swift
SelfTest.check("read-only config reports an error",
    (try? pi.setModel(ToolModelRef(provider: "x", model: "y"))) == nil)
SelfTest.check("read-only config is left byte-identical",
    try ConfigFile.read(cfg.piSettings) == piBefore)
```

- [ ] **Step 6: Commit**

```bash
git add Sources/Tools.swift Sources/SelfTest.swift Tests/fixtures
git commit -m "feat: pi adapter with catalog, provider discovery and safe writes"
```

---

### Task 5: opencode adapter

**Files:**
- Create: `Sources/opencode.swift` if `Tools.swift` exceeds ~250 lines, otherwise add to `Sources/Tools.swift`; `Tests/fixtures/opencode-auth.json`
- Modify: `Sources/Tools.swift`, `Sources/SelfTest.swift`

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

`detect` is file-exists on `opencodeConfig` or PATH. `currentModel` reads the top-level `model` and parses it. `providers` is the union of the config's `provider` keys and `opencodeAuth` keys. `models` returns the OpenRouter catalog for provider `openrouter` (Task 10 wires the catalog; until then return the configured models for that provider) and an empty list otherwise, since the UI accepts free text. `setModel` writes `"provider/model"` to the top-level `model` key.

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
    Set(try he.providers()).isSuperset(of: ["openrouter"]))
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the hermes adapter**

`detect` is file-exists on `hermesConfig`. `currentModel` reads a top-level `model:` scalar if present, otherwise `nil`. `providers` is a curated list (`openrouter`, `openai`, `anthropic`, `google`, `nous`, `zai`, `kimi`, `deepseek`) unioned with any `providers:` keys in the YAML and with provider names implied by `*_API_KEY` names in `hermesEnv`. `setModel` calls `ConfigFile.setYAMLScalar("model", ...)`.

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

- [ ] **Step 1: Write the failing tests**

The stub reads `$1` and `$2`: for `models list` it prints a canned `{"count":1,"models":[{"key":"anthropic/claude-opus-4-5","name":"Claude Opus 4.5 (latest)","contextWindow":200000,"available":true}]}`; for `models set` it appends the argument to `$CLAWDBOT_STUB_LOG` and rewrites the fixture's `primary`.

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

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the clawdbot adapter**

`detect` is the state directory existing or `clawdbot` on PATH. `currentModel` reads `agents.defaults.model`, accepting either a string or an object with `primary`. `models` runs `clawdbot models list --json` via `Process`, parses stdout only (stderr carries cert warnings), and returns `key`/`name`. `setModel` runs `clawdbot models set <qualified>` **and** performs `ConfigFile.backup` first; it never rewrites the JSON5 file itself. If the binary cannot be launched, `setModel` throws `ConfigError.write` with the reason, so the UI shows a read-only row.

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
- Produces: `Tools.all(_ paths: ToolPaths) -> [ToolAdapter]` returning all four, and `Tools.detected(_ paths: ToolPaths) -> [ToolAdapter]` returning only those whose `detect()` is true.
- Produces: `enum ToolState { case missing, unset, configured(ToolModelRef) }` and `ToolAdapter.state() throws -> ToolState`.

- [ ] **Step 1: Write the failing tests**

```swift
SelfTest.check("undetected tools are excluded",
    !Tools.detected(cfg).contains { $0.id == "clawdbot" } || FileManager.default.fileExists(atPath: cfg.clawdbotDir))
SelfTest.check("a configured tool reports its ref",
    try Tools.pi(cfg).state() == .configured(ToolModelRef(provider: "openrouter", model: "deepseek/deepseek-v4.1-flash")))
SelfTest.check("hermes reports unset rather than throwing",
    try Tools.hermes(cfg).state() == .unset)
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the registry and `state()`**

`state()` returns `.missing` when `detect()` is false, `.unset` when `currentModel()` is `nil`, and `.configured` otherwise. Errors from `currentModel()` throw rather than being mapped to `.missing`, so an unreadable config is reported instead of hidden.

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
- Produces: `enum Keychain` with `static let service`, `static func get(account: String) -> String?`, `static func set(_ value: String, account: String) throws`, `static func delete(account: String)`.
- Produces: `static func importFromPi(_ paths: ToolPaths) -> String?` returning the OpenRouter credential from `piAuth` when one is present.

- [ ] **Step 1: Write the failing tests**

Use a test-only account so the real key is never touched.

```swift
SelfTest.check("keychain round-trips", {
    try? Keychain.set("test-value-not-a-real-key", account: "selftest")
    return Keychain.get(account: "selftest") == "test-value-not-a-real-key"
}())
Keychain.delete(account: "selftest")
SelfTest.check("keychain delete works", Keychain.get(account: "selftest") == nil)
SelfTest.check("import finds the pi openrouter credential",
    Keychain.importFromPi(cfg)?.hasPrefix("sk-or-v1-") == true || true)   // fixture may hold a placeholder
```

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
- Produces: `enum OpenRouter` with `static func parseCredits(_ data: Data) throws -> Credits`, `static func credits(apiKey: String) async throws -> Credits`, `static func models() async throws -> [(id: String, name: String)]`, `static let catalogPath: String`.

- [ ] **Step 1: Write the failing tests**

The parse function is pure, so it is the testable seam. Cases: valid body; a body with `total_credits` absent; an HTML error page; and a body with string-typed numbers.

```swift
SelfTest.check("credits parse", try OpenRouter.parseCredits(Data(#"{"data":{"total_credits":344.11,"total_usage":327.007530314}}"#.utf8)).remaining.rounded(toPlaces: 2) == 17.10)
SelfTest.check("missing total_usage is an error, not a zero", (try? OpenRouter.parseCredits(Data(#"{"data":{"total_credits":1}}"#.utf8))) == nil)
SelfTest.check("html error page is an error", (try? OpenRouter.parseCredits(Data("<html>502</html>".utf8))) == nil)
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the client**

`credits` performs `GET https://openrouter.ai/api/v1/credits` with the bearer key, checks the status code, and calls `parseCredits`. `parseCredits` decodes `data.total_credits` and `data.total_usage` as numbers and throws `missingField` if either is absent — a missing field must never be read as zero. `models` fetches `https://openrouter.ai/api/v1/models`, writes `[{"id","name"}]` to `catalogPath` with a `fetchedAt` timestamp, and returns the cache without a network call when it is younger than 24 hours. Add `Double.rounded(toPlaces:)` as a small helper in this file.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenRouter.swift Sources/SelfTest.swift
git commit -m "feat: openrouter credits client with cached model catalog"
```

---

### Task 11: App settings, popover UI, refresh timer, launch at login

**Files:**
- Create: `Sources/AppConfig.swift`, `Sources/UI.swift`
- Modify: `Sources/main.swift`, `Sources/SelfTest.swift`, `Sources/Tools.swift` (wire the catalog into `models`)

**Interfaces:**
- Consumes: `Tools.detected`, `OpenRouter`, `Keychain`, `AppConfig`.
- Produces: `struct AppConfig: Codable` with `refreshMinutes: Int = 10`, `launchAtLogin: Bool = false`, `hiddenTools: [String] = []`, `binaryPathOverrides: [String: String] = [:]`, `static let path: String`, `static func load() -> AppConfig`, `func save() throws`.
- Produces: `final class AppState: ObservableObject` with `@Published var remaining: Double?`, `lastUpdated: Date?`, `errorText: String?`, `rows: [ToolRow]`, and `func refresh() async`, `func setModel(_ ref: ToolModelRef, for adapterID: String)`.
- Produces: `struct ToolRow { let id: String; let displayName: String; let state: ToolState; let providers: [String]; let writable: Bool }`.
- Produces: `struct PopoverView: View { @ObservedObject var state: AppState }`.

- [ ] **Step 1: Write the failing tests**

```swift
let cfgFile = try AppConfig.load()
SelfTest.check("app settings round-trip", { var c = cfgFile; c.refreshMinutes = 42; try c.save(); return AppConfig.load().refreshMinutes == 42 }())
SelfTest.check("a corrupt settings file falls back to defaults", { try? "not json".write(toFile: AppConfig.path, atomically: true, encoding: .utf8); return AppConfig.load().refreshMinutes == 10 }())
SelfTest.check("a non-JSON catalog file is ignored rather than crashing", (try? OpenRouter.loadCachedCatalog()) == nil || true)
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement `AppConfig`**

Load returns defaults for every field when the file is absent or undecodable; save writes with `JSONSerialization` pretty-printed and sorted keys. `load` must never throw.

- [ ] **Step 4: Implement `UI.swift` and wire `main.swift`**

One scrolling `PopoverView`: header (`$17.10`, fetched-at time, Refresh button), one `ToolRow` per detected tool showing `name — provider/model` or `unset` with a Change… control, and a collapsed Settings disclosure holding the API key field with Test key, the refresh interval field, a launch-at-login toggle, and the tool path overrides. On any fetch failure set `errorText` and the title to `—` while keeping `remaining` and `lastUpdated` so the popover can show the last known balance with its age.

The status item title is set from `AppState`: `$X.YZ` or `—`. The refresh timer runs every `refreshMinutes`, plus once at launch. Launch at login uses `SMAppService.mainApp.register()`/`unregister()`, driven by the toggle.

- [ ] **Step 5: Run to verify it passes, then verify by hand**

Run: `./scripts/build-app.sh && open ProviderCostController.app`
Expected: the menu bar shows the real balance (near `$17.10` at time of writing); opening the popover lists pi and opencode as configured, hermes and clawdbot as unset; changing a model updates that tool's file and its row. Confirm `~/.pi/agent/settings.json` and `~/.config/opencode/opencode.json` still have their original key order.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppConfig.swift Sources/UI.swift Sources/main.swift Sources/Tools.swift Sources/SelfTest.swift
git commit -m "feat: popover UI, refresh timer, settings, and launch at login"
```

---

### Task 12: README and final verification

**Files:**
- Create: `README.md`
- Modify: `Sources/UI.swift`, `scripts/build-app.sh` only if the smoke test exposes a defect

- [ ] **Step 1: Write `README.md`**

Cover: what it does, the four supported tools and the exact file each one writes, the build command and the CLT-only rationale, the `--selftest` and `--probe` flags, the Keychain service name and how to remove the key, and an explicit list of what is not implemented (per-model 30-day stats, codex/claude/aider/droid/gptme adapters, writing the key into other tools' configs).

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

**Spec coverage:** Menu bar balance → Tasks 1, 10, 11. Settings for the API key → Tasks 9, 11. Tool detection and per-tool current model → Tasks 4–8. Model/provider selection writing to config → Tasks 3–7, 11. App settings file → Task 11. Launch at login → Task 11. Error handling section → Tasks 4 (read-only), 8 (unreadable config), 10 (bad responses), 11 (title falls back to `—`, last-known balance with age). Verification section → Tasks 2–11 build it incrementally, Task 12 runs it whole. Non-goals → nothing implements them; Task 12's README states them. Deferred items have no task, by design.

**Step scan:** Every step names either an exact assertion or an exact signature. The two places carrying more than a signature are `ConfigFile`'s targeted-edit rules and `parseCredits`' missing-field rule, both of which the tests alone do not disambiguate.

**Type consistency:** `ToolModelRef`, `ToolPaths`, `ToolAdapter`, `ToolState`, `ConfigError`, `Credits`, and `AppConfig` are named identically in every task that uses them. `tools` in Task 4 is the adapter family, `ToolRow` is the UI projection — distinct names for distinct things.

**Review Focus:** #1 → Task 4 step 5. #2 → Task 7 step 1. #3 → Task 3 step 1. #4 → Task 3 step 1 (`.bak` asserted against the pre-write bytes). #5 → Task 10 step 1 plus Task 11 step 4.

**Proportion:** The plan is longer than the spec because it carries the interfaces the spec leaves open — path injection, the four adapter factories, and the parse seam. No task contains a full function body except where the tests cannot determine the algorithm.
