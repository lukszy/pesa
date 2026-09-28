# Harness registry + OpenRouter provider details — Design

**Date:** 2026-09-28
**Status:** Draft, pending user review
**Repo:** `provider-cost-controller`
**Supersedes nothing; extends** `2026-09-28-provider-cost-controller-design.md`.

## Problem

Seven changes, presented as one workstream:

1. Remove clawdbot/OpenClaw from the app.
2. Menu bar: hide the price as `...$`, reveal the real figure on hover.
3. Harness editor: for OpenRouter models, let the user choose which upstream
   providers to allow (`provider.only`), and show price in/out, speed, and data
   retention per provider.
4. Make the per-harness editor reachable from Settings.
5. Popover: pad the price above and below.
6. Show an icon per harness.
7. Harnesses must be added by the user in Settings; they must not auto-populate
   the popover.

## Goal

The popover shows only harnesses the user explicitly added. Settings lists every
detected harness (icon, current model, add/remove, Configure…) and is the entry
point to the editor. The editor surfaces OpenRouter endpoint facts so a provider
choice is informed, and records the chosen allow-list.

## Decisions taken (from the human)

- **Q1 — clawdbot: remove entirely.** Delete the adapter, its `ToolPaths`
  fields, the `binaryPathOverrides` config key, fixtures, checks, and README
  references. pi/opencode/hermes remain.
- **Q2 — provider override: `provider.only`, default all.** This is an
  **OpenRouter-level, per-model** preference. It is not a harness setting and is
  never written into any harness config; the app records it in its own
  `config.json` (`providerOnly[modelID]`).

## Q2 constraint (confirmed by the human)

`provider.only` is a field of the **inference request body**
(`/chat/completions`). It is not a config file and not an account setting the
API can write (account-wide allowlists exist only in the web privacy UI), and no
supported harness exposes it either. So it is a **recorded OpenRouter
preference**: the app stores it per model and displays it alongside the live
per-provider price/speed/ZDR table. The app does not claim to apply it to any
harness's requests, and it writes nothing to a harness beyond the model ref it
already writes. (An OpenRouter *preset* would be the only way to actually apply
it; preset management is explicitly out of scope.)

## Non-goals

- Applying `provider.only` to harness requests (see above; option B).
- Fetching/displaying the human-readable provider retention table (docs-only;
  not an API). We show ZDR membership + privacy/ToS links instead.
- Custom icon assets. Icons are SF Symbols mapped by harness id.
- Per-model 30-day usage, ledger parsing, sandboxing, notarization (unchanged
  from the base spec).

## Design

### 1. Clawdbot removal

Delete: `Tools.clawdbot`, `Tools.parseClawdbotModel`, `Tools.canWrite`,
`clawdbotBinaryCandidates`, `detectClawdbot`, `currentClawdbotModel`,
`clawdbotProviders`, `clawdbotModels`, `clawdbotModelEntries`, the clawdbot
`runClawdbot` helper, `ToolPaths.{clawdbotConfig,clawdbotDir,clawdbotBin}`,
`AppConfig.binaryPathOverrides`, `AppState.effectivePaths`' override branch,
fixtures `Tests/fixtures/clawdbot.json` and `Tests/fixtures/bin/clawdbot`, and
`SelfTest.checkClawdbotAdapter` + staging/settings checks that name clawdbot.
`Tools.all` returns `[pi, opencode, hermes]`.

Consequences handled in the plan:
- `ToolRow.writable` is only ever false for the unreadable-config path, and
  those rows are excluded from the grid. Collapse it: drop `writable` from
  `ToolRow`, drop the read-only UI branches, drop `Tools.canWrite`.
- `ConfigChange.affectsRows` currently keys on `binaryPathOverrides`; it now
  keys on `hiddenTools` → `addedHarnesses` only.

### 2. Menu bar redaction `...$`

`MenuBarPresentation.of(redacted: true)` renders `"...$"` instead of `"$••••"`.
The `—` error indicator and the never-fetched `null` case are unchanged (neither
reveals a figure). The existing toggle is relabelled **"Hide the price in the
menu bar until hovered"**. Hover reveal/re-hide is unchanged.

### 3. Harness editor: OpenRouter provider details

New API layer in `OpenRouter.swift`:

```swift
struct EndpointInfo: Equatable {
    let providerSlug: String          // tag (or lowercased provider_name)
    let providerName: String
    let promptPricePerToken: Double?
    let completionPricePerToken: Double?
    let throughputP50: Double?        // tokens/s
    let latencyP50: Double?           // raw p50; see formatter
    let contextLength: Int?
    let quantization: String?
    let zdr: Bool
    let privacyPolicyURL: String?
    let termsOfServiceURL: String?
}
```

- `OpenRouter.parseModelEndpoints(_ data: Data, zdrKeys: Set<String>) throws -> [EndpointInfo]`
  reads `data.endpoints[]`: `tag`/`provider_name`, `pricing.prompt|completion`
  (reuse the existing `price(_:)` sentinel rule), `throughput_last_30m.p50`,
  `latency_last_30m.p50`, `context_length`, `quantization`. `zdr` is
  `zdrKeys.contains("\(model_id)|\(tag)")`.
- `OpenRouter.parseZDR(_ data: Data) throws -> Set<String>` reads
  `GET /api/v1/endpoints/zdr` (`data[]` with `model` + `provider`) into keys.
- `OpenRouter.parseProviders(_ data: Data) throws -> [String: (privacy: String?, tos: String?)]`
  keyed by `slug`, from `GET /api/v1/providers`.
- `OpenRouter.modelEndpoints(modelID:apiKey:) async throws -> [EndpointInfo]`:
  split the model id on the **first** `/` (author, slug); strip a leading `~`
  (pi's alias prefix) before the request. Fetch endpoints + ZDR + providers,
  join in memory. A failure returns `[]` rather than failing the editor.
- In-memory cache in `AppState` keyed by model id with a 1-hour timestamp;
  no disk cache (the data is volatile and small).

Editor (`ModelEditorView`), only when `editProvider == "openrouter"` and a model
is selected:
- The existing `formatModelDetail` line stays (base price + context).
- A provider table: name · `$in/M` · `$out/M` · throughput p50 · ZDR badge ·
  quant · privacy/ToS link.
- **Allowed providers**: one checkbox per endpoint, default all checked. No
  unchecked boxes → `only` is treated as "all" (store nothing). Unchecking
  stores the checked slugs.
- Caption (verbatim intent): "OpenRouter provider routing for this model,
  recorded by this app."

Formatters (pure, checked):
- `formatThroughput(_ tokensPerSecond: Double?) -> String?` → `"45 tok/s"`.
- `formatLatency(_ p50: Double?) -> String?` — the schema says milliseconds but
  its own example is `0.25` for GPT-4 TTFT, which only reads as seconds; values
  below 5 are rendered as seconds, 5 and above as milliseconds, with a
  `ponytail:` comment naming the ambiguity.
- `formatPricePerMillion` already exists as `formatPerMillionTokens`.

### 4. Harness editor from Settings

`SettingsView` gains an **"Agent harnesses"** section above the menu-bar section:
one row per detected harness (icon, display name, current model or `unset`),
a checkbox bound to membership in `addedHarnesses`, and a **Configure…** button
that calls `state.beginEdit(row)` then `HarnessWindow.open(for:state:)`.
Unreadable harnesses render with their error in subdued text and no Configure.
Settings never triggers discovery itself, but `rows` is populated whenever the
popover has been opened; the section shows "Checking agents…" until then.

### 5. Popover price padding

The balance `Text` in `PopoverView.header` changes from `.padding(.vertical, 6)`
to explicit top and bottom padding (12 each), leaving horizontal/centring alone.

### 6. Icons

`ToolAdapter` gains `let symbol: String` (SF Symbol name); `ToolRow` carries it
through. Mapping: `pi` → `circle.hexagongrid`, `opencode` →
`chevron.left.forwardslash.chevron.right`, `hermes` → `paperplane`. Rendered in
the popover tile, the Settings harness row, and the harness window title. A pure
`harnessSymbol(for id:) -> String` is **not** added — the symbol travels on the
adapter/row so there is one source.

### 7. Manual add, no auto-populate

New config key `addedHarnesses: [String] = []`. `hiddenTools` is removed
(ignored on decode, so no migration and no wipe — an old file's `hiddenTools` is
simply not read).

Pure rule in `HarnessTiles`:

```swift
static func visible(rows: [ToolRow], added: Set<String>, failed: [String: String]) -> [ToolRow]
// rows where added.contains(id) && failed[id] == nil
```

`failedCount` is unchanged (rows minus visible). Popover:
- `rows.isEmpty` while discovering → "Checking agents…" (unchanged).
- discovery done and nothing added → "No harnesses added — add one in Settings."
- discovery done, added set non-empty but none visible → same empty state.

Settings owns the add/remove control. `AppState.discoverProviders()` keeps
detecting every installed harness (so Settings can offer them); only the
popover's filter changes. `ConfigChange.affectsRows` now triggers on
`addedHarnesses` (so adding a harness re-runs discovery and the popover updates).

## Config schema delta

```swift
struct AppConfig {
    // removed: hiddenTools, binaryPathOverrides
    var addedHarnesses: [String] = []
    var providerOnly: [String: [String]] = [:]   // model id -> allowed slugs; absent/empty = all
    // unchanged: refreshMinutes, launchAtLogin, showMoneyInMenuBar,
    //   showIconInMenuBar, hidesAmountInMenuBar, notifyBelowEnabled, notifyBelowAmount
}
```

Every field keeps the `decodeIfPresent ?? default` per-field rule. Removing a key
is safe because unknown JSON keys are ignored and absent keys take defaults;
`providerOnly` and `addedHarnesses` default to empty.

## Testing

`--selftest` gains/pins, all offline against `ToolPaths.stagedInTempDir`:
- clawdbot is absent from `Tools.all`, from settings/fixtures, and its old
  config keys decode without error.
- `MenuBarPresentation` redacted text is exactly `...$`; error/never-fetched are
  untouched.
- `parseModelEndpoints`: prices from decimal strings, negative sentinel → nil,
  ZDR key match, missing throughput/latency → nil, malformed body throws.
- `parseZDR` / `parseProviders` shapes; a 403/HTML body throws.
- `formatThroughput` / `formatLatency` (including the <5 seconds branch).
- `HarnessTiles.visible` admits only added+healthy rows; empty and all-unadded
  cases.
- `AppConfig` round-trip with `addedHarnesses`/`providerOnly`, and an old file
  containing `hiddenTools`/`binaryPathOverrides` decodes to defaults for the new
  keys without losing the other settings.
- `ConfigChange.affectsRows` fires on `addedHarnesses` only.

Manual verification (cannot be asserted headless): hover reveal, Settings window
layout, the editor's provider table rendering live OpenRouter data.

## Risks

- **Latency unit.** Ambiguous in the API's own docs; handled by the magnitude
  formatter with a named ceiling.
- **`~` alias ids.** pi's `models-store.json` can carry `~anthropic/...`; the
  endpoints path must strip it or 404.
- **Endpoints/ZDR fetch failures.** Must degrade to the existing base price
  line, never blank the editor (same rule as `/key`).
- **Removing `hiddenTools`.** A user who had hidden tools will see the popover
  empty until they add harnesses. This is the requested behaviour, but it is a
  visible behaviour change and should be in the README.
