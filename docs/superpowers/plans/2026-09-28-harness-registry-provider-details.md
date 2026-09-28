# Harness registry + OpenRouter provider details — Implementation Plan

> **For agentic workers:** execute task-by-task; every task ends with
> `./scripts/build.sh` and `./.build/ProviderCostController --selftest` green.
> Tasks are sequential (they share `Tools.swift` / `UI.swift` / `SelfTest.swift`).

**Goal:** Remove clawdbot; make the popover opt-in per harness; add Settings
harness management, per-harness icons, `...$` menu-bar redaction, popover price
padding, and an OpenRouter per-model provider table + recorded `provider.only`.

**Architecture:** One `LSUIElement` AppKit process, `swiftc`, no dependencies.
Discovery still detects every installed harness; only the popover's filter is
opt-in, driven by `AppConfig.addedHarnesses`. OpenRouter endpoint/ZDR/provider
facts are fetched lazily per selected model and cached in memory.

**Spec:** `docs/superpowers/specs/2026-09-28-harness-registry-provider-details-design.md`

## Global constraints

- Build: `./scripts/build.sh`. Check: `./.build/ProviderCostController --selftest`.
- No XCTest, no SwiftPM, no third-party deps.
- Selftest never reads/writes a real user path; use `ToolPaths.stagedInTempDir`.
- No vacuous checks (`<cond> || true`).
- Missing datum renders as omitted/`—`, never `$0.00`.
- Do not edit `.env`, `auth/`, `secrets/`, or the Keychain except the
  `selftest` account.
- Do not push or merge; hand back a branch for review.

---

### Task 1: Remove clawdbot/OpenClaw

**Files:** `Sources/Tools.swift`, `Sources/ToolPaths.swift`,
`Sources/AppConfig.swift`, `Sources/UI.swift`, `Sources/SelfTest.swift`,
delete `Tests/fixtures/clawdbot.json`, `Tests/fixtures/bin/clawdbot`, `README.md`.

**Interfaces:**
- `Tools.all` → `[pi, opencode, hermes]`; no `Tools.canWrite`.
- `ToolPaths` loses `clawdbotConfig/Dir/Bin`.
- `AppConfig` loses `binaryPathOverrides`.
- `ToolRow` loses `writable`; `discoverAdapters` stops computing it and the
  ModelEditorView read-only branches are deleted.

- [ ] Delete the clawdbot closure, its free functions, and `runClawdbot`.
- [ ] Delete the three `ToolPaths` fields and `AppConfig.binaryPathOverrides`;
      drop the `effectivePaths` override branch (it becomes `paths`).
- [ ] `ConfigChange.affectsRows` stops referencing `binaryPathOverrides`
      (Task 2 gives it `addedHarnesses`); for now key it on `hiddenTools` only.
- [ ] Delete `SelfTest.checkClawdbotAdapter` and the clawdbot clauses in
      `checkRegistry`/`checkStaging`/staging checks; drop the fixtures.
- [ ] README: remove the clawdbot row, the JSON5/CLI paragraphs, and the
      `binaryPathOverrides` Settings bullet.
- [ ] Build + selftest green.

### Task 2: Config schema — `addedHarnesses`, `providerOnly`, drop `hiddenTools`

**Files:** `Sources/AppConfig.swift`, `Sources/UI.swift`, `Sources/SelfTest.swift`.

**Interfaces:**
```swift
var addedHarnesses: [String] = []
var providerOnly: [String: [String]] = [:]   // model id -> slugs; absent/empty == all
```

- [ ] Add both fields with the per-field `decodeIfPresent ?? default` rule; keep
      the "present-but-mistyped costs only its own field" behaviour.
- [ ] Remove `hiddenTools` from the struct and decode (old JSON is ignored).
- [ ] `ConfigChange.affectsRows` → `old.addedHarnesses != new.addedHarnesses`.
- [ ] `AppState.discoverProviders` stops filtering on `hiddenTools` (discovery
      detects all installed harnesses; the popover filters in Task 5).
- [ ] Selftest: round-trip both new fields; an old file with
      `hiddenTools`/`binaryPathOverrides` decodes with all other settings intact;
      `affectsRows` fires on `addedHarnesses` only.
- [ ] Build + selftest green.

### Task 3: Harness icons

**Files:** `Sources/Tools.swift`, `Sources/UI.swift`, `Sources/SelfTest.swift`.

- [ ] `ToolAdapter.symbol: String`; set `pi`→`circle.hexagongrid`,
      `opencode`→`chevron.left.forwardslash.chevron.right`, `hermes`→`paperplane`.
- [ ] `ToolRow.symbol`; carry it through `discoverAdapters`.
- [ ] Render an `Image(systemName:)` before the name in the popover tile, the
      Settings harness row, and the `HarnessWindow` title.
- [ ] Build + selftest green (registry check asserts each symbol is non-empty).

### Task 4: Menu-bar `...$` redaction

**Files:** `Sources/UI.swift`, `Sources/SelfTest.swift`, `README.md`.

- [ ] `MenuBarPresentation.of`: redacted text `"$••••"` → `"...$"`; `—` and the
      never-fetched `nil` case unchanged.
- [ ] Relabel the toggle **"Hide the price in the menu bar until hovered"**.
- [ ] Selftest: redacted text is exactly `...$`; error still `—`; `nil` still nil.
- [ ] README: update the menu-bar presentation paragraph.
- [ ] Build + selftest green.

### Task 5: Opt-in popover + price padding

**Files:** `Sources/UI.swift`, `Sources/SelfTest.swift`.

- [ ] `HarnessTiles.visible(rows:added:failed:)` → rows where
      `added.contains(id) && failed[id] == nil`; `failedCount` unchanged.
- [ ] `PopoverView.toolList` uses `state.config.addedHarnesses`; empty states:
      discovering → "Checking agents…"; done, nothing added/visible → "No
      harnesses added — add one in Settings."
- [ ] Balance `Text` padding → `.padding(.top, 12).padding(.bottom, 12)`.
- [ ] Selftest: only added+healthy rows survive; unadded and failed both drop;
      `failedCount` still counts only row-backed failures.
- [ ] Build + selftest green.

### Task 6: Settings "Agent harnesses" section

**Files:** `Sources/UI.swift`.

- [ ] Section above Menu bar: per `state.rows` row → icon, name, model text,
      a checkbox bound to `addedHarnesses`, and **Configure…** →
      `state.beginEdit(row); HarnessWindow.open(for: row, state: state)`.
- [ ] Unreadable rows (`state.rowErrors[id] != nil`) show subdued error text and
      no Configure.
- [ ] Pre-discovery (`!hasCompletedDiscovery`) → "Checking agents…".
- [ ] Adding/removing writes `config.addedHarnesses`; `didSet` re-runs discovery
      because `ConfigChange.affectsRows` is true.
- [ ] Build + selftest green.

### Task 7: OpenRouter endpoints / ZDR / providers layer

**Files:** `Sources/OpenRouter.swift`, `Sources/UI.swift`, `Sources/SelfTest.swift`.

**Interfaces:**
```swift
struct EndpointInfo: Equatable {
    let providerSlug: String, providerName: String
    let promptPricePerToken: Double?, completionPricePerToken: Double?
    let throughputP50: Double?, latencyP50: Double?, contextLength: Int?
    let quantization: String?, zdr: Bool
    let privacyPolicyURL: String?, termsOfServiceURL: String?
}
static func parseModelEndpoints(_ data: Data, zdrKeys: Set<String>) throws -> [EndpointInfo]
static func parseZDR(_ data: Data) throws -> Set<String>            // "model|provider"
static func parseProviders(_ data: Data) throws -> [String: (privacy: String?, tos: String?)]
static func modelEndpoints(modelID: String, apiKey: String) async throws -> [EndpointInfo]
func formatThroughput(_ v: Double?) -> String?     // "45 tok/s"
func formatLatency(_ v: Double?) -> String?        // <5 -> seconds, else ms (ponytail note)
```

- [ ] Parsers: reuse `price(_:)` (negative sentinel → nil); missing throughput/
      latency/quant → nil; malformed body / 403 / HTML throws.
- [ ] `modelEndpoints`: split model id on the **first** `/`, strip a leading `~`;
      GET `/models/{a}/{s}/endpoints` + `/endpoints/zdr` + `/providers`; join.
- [ ] `AppState.editEndpoints: [EndpointInfo]` + a 1-hour in-memory cache keyed
      by model id; fetch on model selection; failure → `[]`, never blanks the
      editor's base price line.
- [ ] Selftest: decimal-string prices, negative sentinel, ZDR match, missing
      fields, both latency branches, provider join.
- [ ] Build + selftest green.

### Task 8: Editor provider table + recorded allow-list

**Files:** `Sources/UI.swift`, `Sources/AppState` in `UI.swift`, `README.md`.

- [ ] When `editProvider == "openrouter"` and a model is selected, render the
      endpoint table (name · `$in/M` · `$out/M` · throughput · ZDR · quant ·
      privacy link) under the existing `formatModelDetail` line.
- [ ] "Allowed providers" checkboxes, all checked by default; no unchecks →
      remove `providerOnly[model]`; otherwise store the checked slugs.
- [ ] Caption: "OpenRouter provider routing for this model, recorded by this app."
- [ ] README: document `addedHarnesses`, `providerOnly`, the opt-in popover, and
      the icons.
- [ ] Build + selftest green.

### Task 9: Whole-change verification

- [ ] `./scripts/build.sh` and `--selftest` green from a clean `.build`.
- [ ] `grep -ri clawdbot Sources Tests README.md` → no hits.
- [ ] Verifier sub-agent: reject if any task's check is vacuous, if the popover
      still auto-tiles unadded harnesses, or if a missing price/throughput/ZDR
      renders as a numeric default.
- [ ] Report the diff and evidence; do not merge.

## Review focus

1. A model id containing a slash or a leading `~` must not 404 the endpoints call.
2. A failed endpoints/ZDR fetch must leave the editor usable.
3. Removing `hiddenTools` must not wipe unrelated settings on an upgrade.
4. The popover must never show a harness the user did not add.
