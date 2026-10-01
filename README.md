<div align="center">
  <img src="Resources/logo.png" alt="Pesa logo" width="128" height="128">
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
your machine. It is a single `LSUIElement` process: no Dock icon, no persistent
daemon, and no third-party dependencies.

## Features

- **Live OpenRouter balance** in the menu bar and as the popover headline,
  refreshed at launch, on a configurable timer, and on demand.
- **Per-key usage tiles** — today, week, and month spend, plus key limit, BYOK,
  expiry, and free-tier state when those apply.
- **Opt-in agent harnesses** — pi, opencode, and hermes are detected, but only
  the ones you add appear in the popover.
- **Model editing** — a searchable picker (or free text) writes the chosen
  provider/model back to that harness's own config, after a `.bak` backup. The
  popover tile and the editor show the model's base OpenRouter in/out rates when
  known, and the tile shows the provider that served the last request (`via
  Together`; pi only, since it records the OpenRouter generation id).
- **OpenRouter provider routing** — a live per-provider table (price, speed,
  ZDR, quantization, privacy links) and a recorded per-model allow-list.
- **Low-balance alert** — opt-in local notification on a crossing below your
  threshold; the menu bar amount also turns orange while below it.
- **No third-party dependencies** — built directly against AppKit and SwiftUI.

## Install

Requires **macOS 13 or later**.

Download the latest `Pesa-<version>-<arch>.dmg` from the repository's **Actions**
tab (the `Pesa-macos` artifact of a successful run; a `.zip` is uploaded too),
open the disk image, and drag **Pesa** into **Applications**.

The build is ad-hoc signed and not notarized, so macOS blocks the first launch as
an "unidentified developer". Right-click the app and choose **Open**, or clear
the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Pesa.app
```

Building from source (Xcode Command Line Tools only) gives the same result:

```sh
./scripts/build-app.sh   # swiftc -> Pesa.app
open Pesa.app
```

## Supported tools

Pesa reads and writes the model each tool uses, backing the file up to
`<file>.bak` before every write. Detection finds every installed tool, but only
the harnesses you add in Settings appear in the popover.

| Tool | Config file | Reads / writes |
|---|---|---|
| **pi** | `~/.pi/agent/settings.json` | `defaultProvider` + `defaultModel` |
| **opencode** | `~/.config/opencode/opencode.json` | top-level `model` |
| **hermes** | `~/.hermes/config.yaml` | top-level `model:` |

A tool that is not detected is hidden, and one whose config cannot be read is
reported in a subdued footer line rather than shown as `unset`. Model ids split
on the first `/`, so `deepseek/deepseek-v4.1-flash` works, and the selector is
searchable — text that matches no catalog model is still accepted.

## The API key

Settings has a **Store key in** picker:

- **File** (default) — the `apiKey` field in `~/.pesa-app/settings.json`. The
  directory and file are owner-only, but the value is **not encrypted**.
- **Keychain** — the macOS login Keychain (service `pesa`). macOS asks for
  access once; a rebuild with an ad-hoc signature makes it ask again.

Switching backends carries the key across and clears the old one, so it never
lives in two places, and the key is never logged. **Save**, **Test key**, and
**Clear** all act on the selected backend.

## Settings

Settings live in `~/.pesa-app/settings.json` — plain JSON that, in file key mode,
contains the API key in plain text. They cover the key and where it is stored,
the refresh interval, launch at login, the popover harnesses, per-model provider
allow-lists, menu bar presentation, and the low-balance threshold.

- **Launch at login** needs the `.app` bundle; the raw `.build/` binary reports
  that the bundle is required.
- **Menu bar** — the balance and the icon are independent toggles, but if the
  text is hidden the icon is always drawn so the item stays clickable. **Hide the
  price until hovered** shows `...$` and reveals the figure on hover. Below the
  alert threshold the text turns orange, the `...$` included.
- **Low-balance alert** — opt-in, and fires only on a crossing below the
  threshold, never on a state, so it does not re-notify on every refresh. It
  also needs macOS notification permission.

The window is an app-owned, resizable Settings window (sidebar: **General**,
**API Key**, **Menu Bar**, **Agent Harnesses**, **Alerts**, **About**), opened
with ⌘, or from the status item's right-click menu. The model editor is the
Agent Harnesses detail pane: a change is written to the harness immediately,
with no Set button.

## Not implemented

- **Per-model 30-day usage statistics** — needs a management key; a normal key
  gets HTTP 403 from `/api/v1/activity`.
- **Adapters for codex, claude, aider, droid, gptme, or cursor.**
- **Writing the OpenRouter key into other tools' config files.**
- **Sandboxing, notarization, and auto-update.**

## License

Not yet specified.
