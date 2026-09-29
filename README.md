<div align="center">
  <img src="Resources/logo.svg" alt="Pesa logo" width="128" height="128">
  <h1>Pesa</h1>
  <p><strong>OpenRouter balance and agent-model control, in the macOS menu bar.</strong></p>
  <p>
    <img alt="version 0.1.0" src="https://img.shields.io/badge/version-0.1.0-blue">
    <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black">
    <img alt="dependencies none" src="https://img.shields.io/badge/dependencies-none-brightgreen">
    <img alt="license not specified" src="https://img.shields.io/badge/license-not%20specified-lightgrey">
  </p>
</div>

## What it is

Pesa is a macOS menu bar app that shows your OpenRouter remaining balance and
lets you read and change the model configured in the coding agents installed on
your machine — clicking a harness's tile in the popover opens the Settings
window at that harness's model editor.

It is a single `LSUIElement` process: no Dock icon, no persistent daemon, and
no third-party dependencies.

## Features

- **Live OpenRouter balance** in the menu bar and as the popover's headline
  figure, refreshed at launch, on a configurable timer, and on demand.
- **Per-key usage tiles** — today, week, and month spend on the stored key,
  plus key limit, BYOK, expiry, and free-tier state when those apply.
- **Opt-in agent harnesses** — pi, opencode, and hermes are detected, but only
  the ones you add appear in the popover.
- **Model editing** — a searchable picker (or free text) writes the chosen
  provider/model back to that harness's own config, with an automatic `.bak`.
- **OpenRouter provider routing** — a live per-provider table (price, speed,
  ZDR, quantization, privacy links) and a recorded per-model allow-list.
- **Low-balance alert** — opt-in local notification on a crossing below your
  threshold, never on a state.
- **No third-party dependencies** — built directly with `swiftc`.

## Install

Requires **macOS 13 or later** and the **Xcode Command Line Tools**
(`xcode-select --install`). There is no Homebrew formula or signed release yet,
so build from source:

```sh
./scripts/build.sh        # swiftc -> .build/Pesa (fast, no bundle)
./scripts/build-app.sh    # build + assemble + sign Pesa.app
open Pesa.app
```

`build-app.sh` signs with a stable self-signed identity when one exists and
falls back to an ad-hoc signature otherwise. For launch-at-login and a Keychain
identity that survives rebuilds, create the identity once — see
[Stable signing identity](#stable-signing-identity).

## How it works

- **Balance** — remaining credit (`total_credits − total_usage`) from
  OpenRouter's `GET /api/v1/credits`, rendered in the menu bar and as the large
  centred headline figure in the popover. It refreshes at
  launch, on a timer (default 10 minutes, configurable), and on demand with the
  refresh icon in the popover's top-trailing corner. On a failed fetch the menu
  bar shows `—` and the popover keeps the last known balance with its age; a
  balance that has never been fetched shows `—` in the same large style rather
  than a `$0.00` lie.
- **Stat tiles** — under the balance, equal-sized cards four to a row, one card
  per present figure (a card is omitted, never shown as `$0.00`). The **Key
  limit** card is the exception: it spans the full width of its own row, because
  it carries the progress bar and a longer caption.
  The per-key cards come from OpenRouter's `GET /api/v1/key`:
  - **Today**, **Week**, **Month** — spend on the stored API key
    (`usage_daily`/`usage_weekly`/`usage_monthly`). These are OpenRouter's own
    per-key counters and follow OpenRouter's clock: daily resets at UTC
    midnight, weekly is Monday–Sunday UTC.
  - **Key limit** — the key's spend cap: remaining of the cap, with a thin
    progress bar and the reset period (`limit_remaining`/`limit`/
    `limit_reset`). A key with no cap (`limit` null) shows no card.
  - **BYOK** — own-provider-key spend (`byok_usage`), only when non-zero.
  - **Key** — `expires in Nd` when the key expires inside 30 days, or
    `expired` once past (`expires_at`). No card when it never expires.
  - **Tier** — `free` when `is_free_tier` is true.
  **Account spent** is the account-wide card, from `GET /api/v1/credits`:
  total spent of credits purchased, with its share (omitted when nothing has
  been purchased, where the share is undefined).

  The per-key cards and the account-wide card are kept apart on purpose: with
  more than one key they do not reconcile. A failed `/key` call hides every
  per-key card rather than failing the refresh or blanking the balance, and a
  missing required usage field is treated as an error, never as `$0.00`.
- **Opt-in popover** — the popover shows only the harnesses the user added in
  Settings (`addedHarnesses`); detection still finds every installed harness so
  Settings can offer them, but nothing auto-populates the grid. Each harness row
  and tile carries its own icon (pi → `circle.hexagongrid`, opencode →
  `chevron.left.forwardslash.chevron.right`, hermes → `paperplane`). A detected
  tool whose config cannot be read is hidden and counted in the footer instead.
  Clicking a tile opens the Settings window at that tool's model editor, where
  the built-in searchable model selector (or free text) writes a new one back
  to that tool's own config. For a model that
  is in OpenRouter's public catalog, the editor also shows a line such as
  `1M context · $3.00/M in · $15.00/M out`. Those prices are the **base** rates
  from `pricing.prompt`/`pricing.completion`; the same response carries tiered
  `overrides` (for example, one model costs double above 200k prompt tokens),
  which this app does not present. A missing or unparseable price is omitted
  rather than shown as `$0.00`. A negative `pricing` value is OpenRouter's
  sentinel for variable/unknown pricing (six live models, including
  `openrouter/auto`, ship `"prompt": "-1"`); it is rejected to `nil` rather
  than rendered as negative money, while a genuine free model's `"0"` stays
  valid. The details are parsed from the same `/models` response as the model
  list and **persisted in the 24-hour cache file** alongside it, so a fresh
  cache serves both the selector and the price line without a network fetch. That
  restores the cache short-circuit: `/models` is no longer pulled on every
  refresh.
- **OpenRouter provider routing (recorded)** — for an OpenRouter model the
  editor adds a live per-provider table (name · `$in/M` · `$out/M` · throughput
  p50 · a ZDR badge · quantization · privacy/ToS links), fetched from
  `/models/{author}/{slug}/endpoints`, `/endpoints/zdr`, and `/providers` and
  cached in memory for one hour. A missing price/speed/ZDR renders as an em
  dash, never `$0.00`; a failed fetch shows no table at all and leaves the base
  price line above it intact. Below the table an **Allowed providers** set of
  checkboxes records the user's choice in `providerOnly[model]` — all checked
  when the key is absent or empty, otherwise the checked slugs. This is an
  OpenRouter-level, per-model preference the app records in its **own**
  `config.json`; it is never written into any harness config, and the app does
  not claim to apply it to a harness's requests. The editor says so on its face:
  *OpenRouter provider routing for this model, recorded by this app.*
- **Agents load asynchronously** — the popover appears immediately and shows
  **Checking agents…** while detection runs, instead of waiting on filesystem
  and CLI detection, which can take seconds.

## Supported tools

Only tools detected on this machine are listed. A detected tool with no model
configured shows `unset`. A tool that is not detected is hidden, and a detected
tool whose config cannot be read is omitted from the tiles — a single subdued
line below the grid reports how many harnesses could not be read, so the
failure is not silent.

| Tool | Detected by | Reads | Writes |
|---|---|---|---|
| **pi** | `~/.pi/agent/settings.json` exists or `pi` on `PATH` | `defaultProvider` + `defaultModel` from `settings.json`; providers from `auth.json`, `models.json`, `models-store.json` | rewrites those two keys in `~/.pi/agent/settings.json` |
| **opencode** | `~/.config/opencode/opencode.json` exists or `opencode` on `PATH` | top-level `model`; providers from the config `provider` block and `~/.local/share/opencode/auth.json` | sets top-level `model` in `~/.config/opencode/opencode.json` |
| **hermes** | `~/.hermes/config.yaml` exists | top-level `model:`; providers from a curated list plus `providers:` keys and `*_API_KEY` names in `~/.hermes/.env` | sets or replaces the top-level `model:` line in `~/.hermes/config.yaml` |

Every write backs the previous file up to `<file>.bak`. The file-based
adapters (pi, opencode, hermes) then apply the change atomically via a
same-directory temp file plus rename. Because **pi writes two keys** (`defaultProvider` then `defaultModel`) as
two backed-up writes, its `.bak` may hold the state after the first of the two
— the new provider with the old model — rather than the original file.

Model references split on the **first** `/` only, so ids that contain slashes
(`deepseek/deepseek-v4.1-flash`) and colons (`qwen3.8:latest`) work. Provider
dropdowns list the providers a tool has configured or authenticated; **hermes
is the exception** — it also offers a built-in curated list of providers it
supports even if they are not configured yet, since a hermes user may be about
to set one up. The model selector is searchable: typing filters the dropdown,
and text that matches no catalog model is still accepted as a free-form id.

## Build

Command Line Tools only — no Xcode project, no SwiftPM, no XCTest.

```sh
./scripts/build.sh          # swiftc -> .build/Pesa
./scripts/build-app.sh      # build + assemble + sign Pesa.app
open Pesa.app
```

`build.sh` compiles every file in `Sources/` directly with `swiftc`. SwiftPM is
not used because `swift package` cannot link its own manifest against
`PackageDescription` on a CLT-only install, and XCTest is not shipped in the
CLT toolchain. `build-app.sh` copies the binary and `Resources/Info.plist` into
the bundle and signs it with the stable identity below when it is present in the
signing keychain, and ad-hoc with `codesign -s -` otherwise.

### Stable signing identity

An ad-hoc signature has no stable identity: its designated requirement is a hash
of the code (`cdhash`), so macOS treats every build as a different program.
Create a self-signed code-signing certificate in the login keychain once (no
admin rights, no trust-store changes):

```sh
./scripts/make-signing-identity.sh
```

`build-app.sh` picks the identity up automatically from then on; the app's
designated requirement is certificate-based and survives code changes. It prints
the resulting requirement after signing (`certificate-based requirement —
stable`, or a `cdhash-based (ad-hoc)` warning with the fix), so an ad-hoc build
is flagged rather than looking successful. A self-signed identity shows as
`CSSMERR_TP_NOT_TRUSTED` in `security find-identity`; both scripts explain that
this is expected and harmless. Override
the choice with `SIGNING_IDENTITY=<name>`, which falls back to ad-hoc if the
name is not in the Keychain. To remove the identity:
`security delete-identity -c "ProviderCostController Signing"`.

## Flags

```sh
./.build/Pesa --selftest   # assert-based suite; prints PASS/FAIL and exits 0 on success
./.build/Pesa --probe      # prints the status item facts: statusItem/button/window/visible
```

`--selftest` runs without touching AppKit, so it works in a plain terminal. The
suite uses only temp directories; it never reads or writes a real tool config,
the real settings file, or `~/.pesa-app`.

## The API key

Settings has a **Store key in** picker with two backends:

- **File** (default) — `~/.pesa-app/settings.json`, the `apiKey` field. The
directory and file are created owner-only (`0700`/`0600`), but the value is
**not encrypted**: anything running as your user can read it, so keep that
directory private.
- **Keychain** — the macOS login Keychain (service `pesa`, account
`openrouter`). Choosing it makes macOS ask to allow access once; click **Always
Allow**. A rebuild with an ad-hoc signature changes the app's identity and makes
it ask again — `scripts/make-signing-identity.sh` gives a stable identity.

Switching the picker carries the stored key to the new backend and clears the
old one, so a key never lives in two places. The key is never logged or included
in an error message. **Save**, **Test key** (calls `/credits` and reports the
result) and **Clear** act on the selected backend. In file mode the settings file
is read at launch and written on every change, so a hand-edit made while the app
is running is not picked up until the next launch.

Older builds always used the Keychain, under service `provider-cost-controller`.
That item is not read now; delete it once with:

```sh
security delete-generic-password -s provider-cost-controller -a openrouter
```

## Settings

Settings live in `~/.pesa-app/settings.json`:

- the OpenRouter API key (`apiKey`; plain text — see [The API key](#the-api-key))
- where the key is stored (`keyStorage`: `file` or `keychain`)
- refresh interval in minutes
- launch at login
- the harnesses shown in the popover (`addedHarnesses`, added and removed in Settings)
- per-model OpenRouter provider allow-lists (`providerOnly`; absent/empty means all providers)
- whether the menu bar shows the balance and whether it shows the icon
- whether the menu bar price is hidden as `...$` until hovered
- whether the low-balance alert is enabled, and its threshold

The file is plain JSON and contains no secrets.

The settings UI is an app-owned `NSWindow` styled like a macOS **Settings**
window, opened from
**Settings…** in the app menu (⌘,) or **Settings…** in the status item's
right-click menu. It is split like the system settings windows: a sidebar of
sections (**General**, **API Key**, **Menu Bar**, **Agent Harnesses**,
**Alerts**, **About**) on the left, one grouped-card detail pane on the right.
It is **resizable**, with a `sidebar.left` item in its title bar that shows or
hides the sidebar. (SwiftUI's `Settings` scene is deliberately not resizable and
puts a SwiftUI toolbar outside the title bar, so the window is created and
configured directly; the scene itself only supplies the `⌘,` menu slot.) There is no gear control in the popover header, so settings
are reachable only from those two menus. The popover itself holds only the
centred balance header, the refresh icon, the per-key usage line and its limit
bar, and the detected-agent tiles.
Right-clicking the menu bar icon opens a small menu with **Settings…**, **Buy
credits…** (opens OpenRouter's credits page in the default browser), and
**Quit**; left-clicking still toggles the popover.

The per-agent model editor is not a separate window. It is the **Agent
Harnesses** pane's detail view in the same Settings window: choosing a harness
(its **Configure…** button or a popover tile, which opens Settings at that
harness) swaps the Agent Harnesses detail pane for the editor. There is no
**Set** button: a provider or model change is written to the harness
immediately, and a **Harnesses** back link returns to the list. Re-selecting the
value the harness already has writes nothing, so opening the editor is
side-effect free. The sidebar stays live while editing, so another section can
be selected without losing the change.

### Launch at login

Uses `SMAppService`. This only works from the `.app` bundle produced by
`scripts/build-app.sh`; running the raw `.build/` binary reports that the bundle
is required rather than pretending the setting worked.

### Menu bar presentation

The balance and the icon are two independent toggles. The invariant is: **if the
text is nil, the icon is present** — a status item must always render something
clickable. That covers the both-cleared case (the icon is still drawn) and also
money-shown/icon-hidden before the first successful fetch, when there is no
balance text yet. A status item with nothing to render would have nothing to
click and the app would become impossible to open or quit. Hiding the balance
affects only the menu bar; the popover always shows it.

The **Hide the price in the menu bar until hovered** setting replaces the
formatted amount with `...$` (the `—` error indicator and the never-fetched case
are unchanged, since neither reveals a figure). Hovering the status item reveals
the real figure and leaving re-hides it, via an `NSTrackingArea` on the status
button; the title is re-rendered on both the hover change and any settings
change. This is text redaction, not a blur: an `NSStatusItem` title is plain
text.

### Low-balance alert

Opt-in. When enabled, the app raises a local notification only on a **crossing**
below the threshold: the previous fetched balance was at or above it and the new
one is below. A balance already below the threshold at launch does not alert,
because nothing was crossed — the app refetches every ten minutes, so alerting
on a state would notify all day.

- Change the threshold with the **Threshold $** field in Settings.
- Disable it by switching **Notify when the balance falls below** off.
- It also requires macOS notification permission; if permission is refused the
  alert stays quiet and Settings reports the permission state. (Notification
  banner display cannot be asserted from the suite; only the crossing decision
  is unit-checked, and delivery itself is manual verification.)

## Not implemented

- **Per-model 30-day usage statistics.** The OpenRouter API cannot serve these
  with a normal API key; only a management key can reach `/api/v1/activity`
  (a normal key gets HTTP 403).
- **Adapters for codex, claude, aider, droid, gptme, or cursor.**
- **Writing the OpenRouter key into other tools' own config files** (for
  example `~/.hermes/.env`). The key is for this app only.
- **Sandboxing, notarization, and auto-update.**

Also deferred: local agent ledgers (pi/opencode session logs).
No placeholder code exists for any deferred item.

## License

Not yet specified.
