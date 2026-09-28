# Provider Cost Controller — Design

**Date:** 2026-09-28
**Status:** Approved design, pending spec review
**Repo:** `provider-cost-controller`

## Problem

Coding agents (pi, opencode, hermes, clawdbot/OpenClaw) each keep their own model
and provider configuration in a different file and format. Checking OpenRouter
spend means opening a browser, and switching which model an agent uses means
hand-editing JSON, YAML, or JSON5 with the right key nesting. There is no single
place to see "what is my balance" and "what model is each agent set to, and
change it".

## Goal

A macOS menu bar app that:

1. Shows the OpenRouter account balance in the menu bar at all times.
2. Shows a settings field for the OpenRouter API key.
3. Detects which agent tools are installed on this machine and, for each one
   found, displays its currently configured provider/model and lets the user
   change it, writing the change back to that tool's config file.

Intended for personal use first, open-source-or-sellable later, so tool paths
and preferences live in a config file rather than being hardcoded.

## Non-goals (explicitly out of scope for v1)

- **Per-model usage stats for the last 30 days.** Dropped by decision. The
  OpenRouter API cannot supply this with a normal API key — see
  [Feasibility findings](#feasibility-findings).
- **Local ledger parsing.** Deferred. pi and opencode both keep full per-message
  cost ledgers on disk that would answer the stats question offline.
- **Spend figures from `/api/v1/key`** (`usage_daily`, `usage_weekly`,
  `usage_monthly`). Available and nearly free, but dropped by decision.
- Adapters for codex, claude, aider, droid, gptme, cursor. Codex in particular
  is installed *and* configured on the reference machine.
- Per-project model configuration, spend graphs/history, sandboxing,
  notarization, auto-update.
- Writing the OpenRouter key into each tool's own config (e.g.
  `~/.hermes/.env`). The key is for this app only. See
  [Future work](#future-work).

No placeholder code is to be written for any deferred item.

## Feasibility findings

All verified against the live machine on 2026-09-28.

### OpenRouter API

| Endpoint | Result |
|---|---|
| `GET /api/v1/credits` | Works. Returns `total_credits` and `total_usage`. Balance = difference. |
| `GET /api/v1/key` | Works. Also returns `usage_daily/weekly/monthly` (account-wide, not per-model). |
| `GET /api/v1/activity` | **403** — `Only management keys can fetch activity for an account`. Per-model daily breakdown is unreachable without a management/provisioning key. |
| `GET /api/v1/models` | Public, no auth. Used as the shared model catalog fallback. |

Balance at time of writing: `344.11 − 327.01 = $17.10`.

### Toolchain

- Swift 6.3.3, macOS 26.6.2, SDK 26.5. `SwiftUI`, `AppKit`, `Security`, and
  `ServiceManagement` all present in the CLT SDK.
- **Only Command Line Tools, no full Xcode.**
- **SwiftPM does not work**: `swift package` fails to link its own manifest
  against `PackageDescription` (`Undefined symbols for architecture arm64`).
  Building with `swiftc` directly works.
- XCTest is not present in the CLT toolchain, so `swift test` is unavailable.
- No `screen recording` permission is granted to the terminal, so visual
  verification via `screencapture` is not possible.

### Build spike (passed, 2026-09-28)

A throwaway app compiled with
`swiftc -O -o Spike Sources/Spike/main.swift -framework AppKit -framework SwiftUI`
and assembled into a hand-written `.app` with `LSUIElement=true`, then ad-hoc
signed with `codesign -s -`, launched and self-reported:

```
statusItem created: true                button.window.isVisible: true
button exists: true                     button.window.frame: {{0,0},{112,0}}
button.window exists: true              button.title: SPIKE$17.10
popover.isShown after toggle: true      popover window visible: true
hosting view size: {280,81}             popover window frame: {{1592,1068},{306,107}}
```

This proves the three assumptions the design rests on: a status item renders in
the menu bar, a SwiftUI view works as `NSPopover` content, and the whole thing
builds, signs, and runs without Xcode.

## Architecture

One executable named `ProviderCostController`, nine source files, zero
third-party dependencies.

```
provider-cost-controller/
├── Sources/
│   ├── main.swift            # NSApplication, status item, popover, timer
│   ├── UI.swift              # AppState + SwiftUI views for the popover content
│   ├── OpenRouter.swift      # /credits + /models, catalog cache
│   ├── Tools.swift           # the 4 tool adapters (detect/read/write)
│   ├── ToolPaths.swift       # tool config path resolution + test staging
│   ├── ConfigFile.swift      # byte-preserving config edits
│   ├── AppConfig.swift       # app's own settings file
│   ├── Keychain.swift        # API key storage
│   └── SelfTest.swift        # the --selftest suite
├── scripts/build-app.sh      # swiftc + .app assembly + ad-hoc sign
└── Tests/fixtures/           # sample configs for --selftest
```

There is no daemon, no helper process, and no background agent. The app is a
single `LSUIElement` process.

### Menu bar

- `NSStatusItem` with a small SF Symbol (`dollarsign.circle`) plus the remaining
  balance as the title, formatted to two decimals, e.g. `$17.10`.
- A left click opens an `NSPopover`. The status item is not a menu; there is no
  right-click menu in v1.
- Refresh triggers: at launch, on a timer (default 10 minutes, configurable),
  and via a Refresh button in the popover.
- On failure the title falls back to `—` and the popover shows the error text.
  No modal alerts and no dock icon. The only notification the app may raise is
  the opt-in low-balance alert described under Settings.

### OpenRouter layer

- `remaining = total_credits − total_usage` from `GET /api/v1/credits`.
- `GET /api/v1/models` for the shared model catalog, cached on disk with a 24
  hour TTL.
- A single `URLSession` wrapper. No networking dependency.

### API key

- Stored in the Keychain as a generic password, service
  `provider-cost-controller`, account `openrouter`. Never written to a plain
  file.
- On first run, if the Keychain has no key and `~/.pi/agent/auth.json` contains
  an OpenRouter credential, the app offers **Import key from pi** so the user
  does not have to type it.
- Settings provides paste, clear, and a **Test key** button that calls
  `/credits` and reports the result.
- The key is never logged and never included in error messages.

### Tool adapters

Four entries in one flat table. Each entry provides: detect, current model,
provider list, model list, and a write operation. This is deliberately not a
protocol with one implementation per tool — it is one structure with four
entries.

| Tool | Detect | Read current model | Provider list | Model list | Write |
|---|---|---|---|---|---|
| **pi** | `~/.pi/agent/settings.json` exists or `pi` on PATH | `defaultProvider` + `defaultModel` | keys of `auth.json` + `providers` in `models.json` + keys of `models-store.json` | `models-store.json[provider].models` (id + display name); custom models from `models.json` | rewrite those two keys in `settings.json` |
| **opencode** | `~/.config/opencode/opencode.json` exists or `opencode` on PATH | top-level `model`, split on the first `/` | keys of the config's `provider` block + keys of `~/.local/share/opencode/auth.json` | OpenRouter catalog, plus free text | set top-level `model` in `opencode.json` |
| **hermes** | `~/.hermes/config.yaml` exists | top-level `model:` (may be absent) | curated known-provider list + `providers:` keys in the YAML + variable names in `~/.hermes/.env` | OpenRouter catalog, plus free text | set or replace the top-level `model:` line |
| **clawdbot** | `~/.clawdbot/` exists or `clawdbot` on PATH | `agents.defaults.model` (a string, or `.primary` when it is an object) | model keys from `models list --json` | `clawdbot models list --json` (key, name, contextWindow, available) | `clawdbot models set <provider/model>` |

Behaviour:

- A tool that is not detected is **hidden**, not shown greyed out.
- A detected tool with no model configured (hermes and clawdbot on the
  reference machine) shows `unset` and a Set button.
- The clawdbot CLI is located by searching a list of standard absolute paths
  (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`) before falling back to
  `PATH`, and the resolved path is used for every invocation. An app launched
  from Finder receives a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so a
  `PATH`-only lookup would never find a CLI installed by Homebrew or npm — the
  clawdbot row would be permanently read-only in the shipped app, which is the
  opposite of the point. This is the one adapter that must *run* a binary rather
  than read a file, so it is the only one where `PATH` matters.
- Provider dropdowns list the providers a tool has configured or authenticated,
  so a local endpoint such as `omlx` or `ollama` is selectable. **Hermes is the
exception:** it also offers a built-in curated list of the providers it supports,
whether or not they are configured yet, because a hermes user may be about to
configure one. That list is deliberate and is not a bug to be removed.
- Model dropdowns list the fetched OpenRouter catalog (falling back to the
  tool's own configured models) and **always accept free text** for anything
  not listed, so `omlx/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit` and
  `ollama/qwen3.8:latest` work exactly like a catalog entry.
- Model references are split on the **first** `/` only, because model ids
  themselves contain slashes (`deepseek/deepseek-v4.1-flash`).
- Changing the provider resets the model selection to that provider's first
  available model; the user confirms before the write. The picker never writes a
  provider/model pair that belongs to different providers.

#### Write strategy

- **pi, opencode, hermes — targeted key edit.** Modify only the bytes belonging
  to the relevant key. Do not parse and re-serialize the document.
  - pi and opencode are JSON, but a full round-trip would reformat the entire
    file; a targeted edit keeps the user's formatting and key order.
  - hermes is YAML; only a top-level scalar `model:` line is handled.
- **clawdbot — subprocess, deliberately.** `~/.clawdbot/clawdbot.json` is
  **JSON5** (the installed loader references `json5` 15 times), so comments and
  trailing commas are legal and a JSON round-trip would silently destroy them.
  `clawdbot models set` is the tool's own supported write path and is immune to
  that. It also supplies `available` flags for the picker for free.
  The clawdbot CLI is a Node process taking seconds to start, so it is invoked
  **only while the popover is open**, never from the refresh timer.
- Every write is preceded by a copy of the original to `<file>.bak`, and is
  applied atomically via a temporary file plus rename.
- Writes are best-effort and version-dependent. A failed write reports the
  error in the UI and leaves the original file untouched.

### App's own settings

`~/Library/Application Support/ProviderCostController/config.json`:

- refresh interval in minutes
- launch at login (via `SMAppService`)
- per-tool binary path override, so a non-standard install can be pointed at
- hidden tools
- whether the menu bar shows the balance
- whether the menu bar shows the icon
- whether the low-balance alert is on, and its threshold in dollars

Plain JSON. Contains no secrets.

### Menu bar presentation

Two independent toggles control what the status item renders: the balance text
and the icon.

- Money shown, icon shown — `$17.10` beside the icon.
- Money hidden, icon shown — the icon alone, which is the compact form.
- Money shown, icon hidden — the balance text alone.
- Both hidden — the icon is still rendered.

The last case is deliberate. A status item with no text and no image has nothing
to click, which would leave the app running and unreachable. The settings panel
states this, so the behaviour is not a surprise.

On a failed fetch the money text becomes `—` (and the last known balance is shown
in the popover with its age). A balance that has never been fetched renders no
money text at all, rather than a misleading zero. Hiding the money affects only
the menu bar; the popover always shows the balance.

### Balance alerts

An optional local notification when the remaining balance falls below a
dollar threshold the user sets.

The alert fires **on a crossing, not on a state**: only when the previous fetched
balance was at or above the threshold and the new one is below it. A balance that
is already below the threshold at launch does not alert, because nothing was
crossed. This matters because the app refetches every ten minutes by default —
an alert on state rather than crossing would fire all day.

It also requires the alert to be enabled in settings and the OS notification
permission to have been granted. If permission is refused the alert simply stays
quiet and the settings panel reports the state; the app never prompts twice or
badgers the user about it.

### Popover layout

One scrolling page, not tabs:

1. Header: balance, a timestamp of when it was fetched, and Refresh.
2. Tools: one row per detected tool — name, current provider/model, Change….
3. A collapsed Settings section with:
   - API key, with Test key
   - refresh interval
   - **Menu bar**: show balance checkbox, show icon checkbox
   - **Alerts**: enable low-balance alert checkbox, threshold amount field
   - launch at login checkbox

## Error handling

- Network failure: title becomes `—`, popover shows the failure and keeps the
  last known balance labelled with its age.
- Missing or invalid API key: popover prompts for the key; no retry storm.
- Config file unreadable or unparseable: that tool's row shows the problem and
  its Change… action is disabled. Other tools remain usable.
- Write failure: error shown, `.bak` retained, original file untouched.
- clawdbot CLI missing while its config directory exists: the row becomes
  read-only and says so.

## Verification

- `ProviderCostController --selftest` runs four fixture configs (one per tool) through
  read → write → read and asserts:
  1. the model changed to the requested value;
  2. **every other byte of the file is unchanged**;
  3. malformed or truncated input cannot corrupt the file — the original
     survives byte-for-byte.
  Plain `assert` statements. No XCTest, which is not available in the CLT
  toolchain.
- The two behaviours that cannot be observed programmatically are factored into
  pure functions so they *can* be checked: the menu bar presentation rule
  (including the both-toggles-off case, which must still render something
  clickable) and the low-balance crossing rule (which must not fire on a state,
  only on a crossing).
- `scripts/build-app.sh` must produce a launchable `.app`.
- Manual smoke test: launch, confirm the menu bar shows the real balance, toggle
  each menu bar checkbox and confirm the item re-renders, and confirm a model
  change is reflected in the target tool's file and in that tool.
- **Not verifiable here:** whether a notification banner actually appears. Screen
  Recording permission is not granted to the terminal, and notification display
  cannot be asserted from a test. The delivery call is therefore manual-only
  verification, and the decision logic it depends on is covered by the pure
  function above.

## Risks

1. **Unsigned app and the Keychain.** An ad-hoc signature's designated
   requirement is a `cdhash`, so it changes whenever the *code* changes (not on
   every rebuild: rebuilding identical source yields the same hash). macOS then
   treats the new build as a different app and re-prompts for Keychain access.
   `scripts/make-signing-identity.sh` creates a stable self-signed code-signing
   identity, and `build-app.sh` uses it when present, giving the app a
   certificate-based designated requirement that survives code changes.
   Cosmetic, not functional.
2. **No Xcode.** Proven workable by the spike, but `swiftc` plus hand-written
   `.app` assembly means no SwiftPM features (dependency resolution, test
   runner) are available. The design avoids needing any.
3. **Config formats drift between tool versions.** Adapters are best-effort
   against the formats observed on 2026-09-28. The `.bak` plus atomic write
   limits the damage, and the selftest fixtures pin the supported shapes.
4. **clawdbot JSON5.** Avoided by delegating writes to its CLI. If the CLI is
   absent while its state directory exists, the adapter degrades to read-only
   rather than attempting a JSON rewrite.
5. **hermes has no CLI on the reference machine**, so its adapter is
   file-edit-only, and it has no model key today. YAML handling is limited to a
   top-level scalar `model:`.
6. **Notifications on an ad-hoc-signed, non-notarized app.** A local notification
   needs a bundle identifier and a granted permission, both of which the app has
   or can request, but an unnotarized app can be silently suppressed by the
   system and the failure is invisible from inside the process. The alert is
   opt-in and degrades to silence, and the settings panel reports the permission
   state so a user can see that it is blocked rather than guessing.

## Future work

- Per-model 30-day stats, from either of the two researched sources: local
  ledgers (pi `~/.pi/agent/sessions/*/*.jsonl` `usage.cost.total` per message;
  opencode `~/.local/share/opencode/storage/message/<session>/*.json` with
  `modelID`, `providerID`, `cost`, `time.created`) or OpenRouter
  `/api/v1/activity` with a management key.
- Spend figures from `/api/v1/key` (`usage_daily/weekly/monthly`).
- Codex (`~/.codex/config.toml`, TOML, `model = "gpt-5.6-terra"`) and other
  adapters. The table makes this one entry each.
- Optionally writing the OpenRouter key into each tool's own secret store
  (`~/.hermes/.env`, `~/.pi/agent/auth.json`).
- Per-project model configuration.
- Stable signing identity, notarization, distribution.
