# Provider Cost Controller

A macOS menu bar app that shows your OpenRouter remaining balance and lets you
read and change the model configured in the coding agents installed on your
machine — clicking a harness's tile in the popover opens that harness's model
editor in its own window.

The app is a single `LSUIElement` process: no Dock icon, no persistent daemon,
and no third-party dependencies. (It does spawn the clawdbot CLI on demand, but
only while the popover is open and only to read or write clawdbot's config.)

- **Balance** — remaining credit (`total_credits − total_usage`) from
  OpenRouter's `GET /api/v1/credits`, rendered in the menu bar and as the large
  centred headline figure in the popover. It refreshes at
  launch, on a timer (default 10 minutes, configurable), and on demand with the
  refresh icon in the popover's top-trailing corner. On a failed fetch the menu
  bar shows `—` and the popover keeps the last known balance with its age; a
  balance that has never been fetched shows `—` in the same large style rather
  than a `$0.00` lie.
- **Per-key usage** — directly under the balance, a compact line such as
  `Today $5.45 · Month $92.17`, from OpenRouter's `GET /api/v1/key`. This is
  **usage for the stored API key**, whereas the balance above it is
  **account-wide**; with more than one key the two figures do not reconcile, so
  the line's tooltip says which is which. When the key has a spend cap
  configured, a thin progress bar shows the remaining share of that cap with
  its reset period (`limit_reset`). A key with no cap (`limit` and
  `limit_remaining` null) shows no bar at all, and a failed `/key` call hides
  the whole line rather than failing the refresh or blanking the balance. A
  missing usage field is treated as an error, never as `$0.00`.
- **Models** — each detected tool is a tile showing its current
  `provider/model` (or `unset`). Clicking a tile opens that tool's model editor
  in its own window, where the built-in picker (or free text) writes a new one
  back to that tool's own config. For a model that is in OpenRouter's public
  catalog, the editor also shows a line such as
  `1M context · $3.00/M in · $15.00/M out`. Those prices are the **base** rates
  from `pricing.prompt`/`pricing.completion`; the same response carries tiered
  `overrides` (for example, one model costs double above 200k prompt tokens),
  which this app does not present. A missing or unparseable price is omitted
  rather than shown as `$0.00`. The details are parsed from the same `/models`
  response as the model list but kept **in memory only** — they are not written
  to the 24-hour cache file, so for the few seconds between launch and the
  first successful fetch the editor shows no price line.
- **Agents load asynchronously** — the popover appears immediately and shows
  **Checking agents…** while detection runs, instead of waiting on clawdbot's
  CLI, which can take seconds.

## Supported tools

Only tools detected on this machine are listed. A detected tool with no model
configured shows `unset`. A tool that is not detected is hidden, and a detected
tool whose config cannot be read is omitted from the tiles — a single subdued
line below the grid reports how many harnesses could not be read, so the
failure is not silent. A tool whose config is readable but has no writable path
— clawdbot with no resolvable CLI and a config the fallback parse can still read
— keeps its tile, and its editor opens with **Set** disabled. With no resolvable
CLI the model falls back to a parse of `clawdbot.json`, and that parse throws on
an absent or comment-laden (JSON5) file, so in the common case that harness is
dropped from the grid and counted in the footer rather than tiled — the
hide-on-failure rule, stated below, is deliberate.

| Tool | Detected by | Reads | Writes |
|---|---|---|---|
| **pi** | `~/.pi/agent/settings.json` exists or `pi` on `PATH` | `defaultProvider` + `defaultModel` from `settings.json`; providers from `auth.json`, `models.json`, `models-store.json` | rewrites those two keys in `~/.pi/agent/settings.json` |
| **opencode** | `~/.config/opencode/opencode.json` exists or `opencode` on `PATH` | top-level `model`; providers from the config `provider` block and `~/.local/share/opencode/auth.json` | sets top-level `model` in `~/.config/opencode/opencode.json` |
| **hermes** | `~/.hermes/config.yaml` exists | top-level `model:`; providers from a curated list plus `providers:` keys and `*_API_KEY` names in `~/.hermes/.env` | sets or replaces the top-level `model:` line in `~/.hermes/config.yaml` |
| **clawdbot** | `~/.clawdbot/` exists or a `clawdbot` binary resolves | `agents.defaults.model` via `clawdbot config get` and the catalog via `clawdbot models list --json` | `clawdbot models set <provider/model>` |

Every write backs the previous file up to `<file>.bak`. The file-based
adapters (pi, opencode, hermes) then apply the change atomically via a
same-directory temp file plus rename; clawdbot's write is performed by its own
CLI. Because **pi writes two keys** (`defaultProvider` then `defaultModel`) as
two backed-up writes, its `.bak` may hold the state after the first of the two
— the new provider with the old model — rather than the original file.

Model references split on the **first** `/` only, so ids that contain slashes
(`deepseek/deepseek-v4.1-flash`) and colons (`qwen3.8:latest`) work. Provider
dropdowns list the providers a tool has configured or authenticated; **hermes
is the exception** — it also offers a built-in curated list of providers it
supports even if they are not configured yet, since a hermes user may be about
to set one up. The model dropdown always accepts free text.

**clawdbot is written through its own CLI, not by editing the file.** Its
config (`~/.clawdbot/clawdbot.json`) is JSON5 with comments and trailing commas,
which a JSON round-trip would destroy. If the CLI cannot be found and its config
is still parseable, its tile is shown read-only rather than risking a rewrite.
The CLI is looked up in standard absolute locations before `PATH`, because a
Finder-launched app receives a minimal `PATH`.

## Build

Command Line Tools only — no Xcode project, no SwiftPM, no XCTest.

```sh
./scripts/build.sh          # swiftc -> .build/ProviderCostController
./scripts/build-app.sh      # build + assemble + sign ProviderCostController.app
open ProviderCostController.app
```

`build.sh` compiles every file in `Sources/` directly with `swiftc`. SwiftPM is
not used because `swift package` cannot link its own manifest against
`PackageDescription` on a CLT-only install, and XCTest is not shipped in the
CLT toolchain. `build-app.sh` copies the binary and `Resources/Info.plist` into
the bundle and signs it with the stable identity below when it is present in the
Keychain, and ad-hoc with `codesign -s -` otherwise.

### Stable signing identity

An ad-hoc signature has no stable identity: its designated requirement is a hash
of the code (`cdhash`), so the requirement changes whenever the code changes and
macOS re-prompts for Keychain access. Create a self-signed code-signing
certificate in the login keychain once (no admin rights, no trust-store
changes):

```sh
./scripts/make-signing-identity.sh
```

`build-app.sh` picks the identity up automatically from then on; the app's
designated requirement is certificate-based and survives code changes. Override
the choice with `SIGNING_IDENTITY=<name>`, which falls back to ad-hoc if the
name is not in the Keychain. To remove the identity:
`security delete-identity -c "ProviderCostController Signing"`.

## Flags

```sh
./.build/ProviderCostController --selftest   # assert-based suite; prints PASS/FAIL and exits 0 on success
./.build/ProviderCostController --probe      # prints the status item facts: statusItem/button/window/visible
```

`--selftest` runs without touching AppKit, so it works in a plain terminal. The
suite uses only temp directories and the `selftest` Keychain account; it never
reads or writes a real tool config or the real settings file.

## The API key

The OpenRouter key is stored in the macOS Keychain only, as a generic password:

- service: `provider-cost-controller`
- account: `openrouter`

It is never written to a plain file, logged, or included in an error message.
The app offers **Test key** (calls `/credits` and reports the result) and
**Clear**.

To remove the key:

```sh
security delete-generic-password -s provider-cost-controller -a openrouter
```

or use the **Clear** button in the app's Settings.

A key saved by an older ad-hoc-signed build has its Keychain ACL bound to the
old code hash. Its first read by the newly certificate-signed app may therefore
still prompt once; click **Always Allow** (or delete and re-save the key from the
new build) to rebind it. The signing identity only stops future prompts.

## Settings

Settings live in
`~/Library/Application Support/ProviderCostController/config.json`:

- refresh interval in minutes
- launch at login
- hidden tools
- per-tool binary path overrides (only clawdbot runs a binary)
- whether the menu bar shows the balance and whether it shows the icon
- whether the low-balance alert is enabled, and its threshold

The file is plain JSON and contains no secrets.

The settings UI is a standard macOS **Settings** window, opened from
**Settings…** in the app menu (⌘,) or **Settings…** in the status item's
right-click menu. There is no gear control in the popover header, so settings
are reachable only from those two menus. The popover itself holds only the
centred balance header, the refresh icon, and the detected-agent tiles.
Right-clicking the menu bar icon opens a small menu with **Settings…**, **Buy
credits…** (opens OpenRouter's credits page in the default browser), and
**Quit**; left-clicking still toggles the popover.

The per-agent model editor opens in its own AppKit window (one window,
retargeted to the clicked harness) rather than in a SwiftUI scene, because the
popover sits outside the SwiftUI scene graph and `openWindow` is unreliable
there. The window is resizable and has **Set** and **Cancel**; Cancel (or
closing the window) dismisses the editor without writing.

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
