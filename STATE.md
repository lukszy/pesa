# Loop State — provider-cost-controller

Last run: 2026-09-28

## High Priority (loop is acting or waiting on human)

- **Branch `feat/harness-registry-provider-details` is ready for review.**
  Worktree: `/Users/l.szymanski/orca/projects/pcc-harness-registry`
  (base commit `58d75a7`, change commits `b428add` + verifier-fix commit). Not
  pushed, not merged. Awaiting human approval to merge.
- **Rename + key storage (commit `43df5c7`):** the app/bundle/executable are
  now **Pesa** (bundle id `local.pesa`), settings and the model cache live in
  `~/.pesa-app`, and the OpenRouter key is a plain-text `apiKey` field in
  `~/.pesa-app/settings.json` by default, with an opt-in Keychain backend
  (`keyStorage`: `file` | `keychain`) selectable in Settings; switching carries
  the key across and clears the old store.
- Scope: remove clawdbot/OpenClaw; opt-in harness registry (`addedHarnesses`)
  with a Settings "Agent harnesses" section (add/remove + Configure…); per-
  harness SF Symbols; menu-bar `...$` redaction on hover; popover price padding;
  OpenRouter per-model provider table (in/out price, throughput, latency, ZDR,
  privacy/ToS) and a recorded `provider.only` allow-list (`providerOnly`).

## Verification evidence

- `./scripts/build.sh` from a clean `.build`: exit 0.
- `./.build/Pesa --selftest`: exit 0, **180 PASS / 0 FAIL** (clean
  `rm -rf .build` first).
- `grep -rni clawdbot Sources Tests README.md scripts`: no hits.
- Live API key-match checked against `GET /endpoints/zdr` +
  `GET /models/anthropic/claude-sonnet-5.5/endpoints`: both carry
  `model_id=anthropic/claude-sonnet-5.5`, `tag=google-vertex/global`.
- SDD workflow `workflow-mulqjydp-3f5bf488a25945e7` (3 implementer phases +
  verifier) returned PASS.
- Final independent verifier re-run on the frozen commit: PASS on all six risk
  claims. Two non-blocking findings, both fixed: the opencode SF Symbol comment
  was wrong (kept the original glyph, macOS 12+), and the `/providers` join now
  falls back to the base slug so region-scoped tags keep their links.

## Watch List

- `formatLatency` uses a magnitude heuristic (below 5 = seconds, else ms)
  because OpenRouter's schema says milliseconds but its example is `0.25`.
- ZDR badge can miss alias model ids (e.g. a `~`-prefixed alias) whose canonical
  permaslug differs; it degrades to "—", never a false "ZDR".
- `providerOnly` is recorded in this app's `config.json` only. OpenRouter's
  `provider.only` is a per-request field, so the selection does not change any
  harness's requests (documented in the design spec).

## Follow-up in the same branch

- `dfa76a0` verifier fixes, then `5a401aa` Keychain read-caching, then a build
  script commit surfacing the signing requirement, then a pure-SwiftUI
  `SearchablePicker` for model selection (`resolveModelSelection` pinned by four
  checks), then an editor pass: provider empty state with an Add button, wider
  editor/window, the allow-list checkboxes moved into the provider table's left
  column, and a sortable provider table (`sortedEndpoints` pinned by six
  checks). The allow-list control is the per-row Allow column; a dropdown
  checklist was added and then removed at the human's request. The editor now
  fills the harness window (820x560 default, 620 minimum). The Settings window
  is now a sidebar + grouped-card layout (General, API Key, Menu Bar, Agent
  Harnesses, Alerts, About), and the harness editor is hosted in that same
  window's detail pane (HarnessWindow deleted). The provider list is now a
  native SwiftUI `Table` (was a custom Grid that collapsed in the pane), with
  column sorting via a `sortOrder` binding. The Settings window is now
  resizable (min 720x520, first size 900x640) on every open path, including
  cmd-commas. The harness editor auto-saves on change (Set/Cancel removed) and
  the sidebar switches freely while editing. The provider table highlights the
  hovered row via its selection binding. Then the Pesa rename and file-based key
  storage, an optional Keychain backend, and a Settings sidebar show/hide toggle
  moved to the window's title-bar NSToolbar. The Settings window is now an
  app-owned resizable NSWindow (the SwiftUI Settings scene is intentionally
  non-resizable per Apple's guidance), with cmd-comma wired through
  CommandGroup(replacing: .appSettings). Selftest 180 PASS / 0 FAIL.
  `build-app.sh` prints
  `certificate-based requirement — stable` or a `cdhash-based (ad-hoc)` warning
  after signing.

## Watch List (additions)

- The API key is plain text in `~/.pesa-app/settings.json` (0600) in the default
  file mode; anything running as the user can read it. The opt-in Keychain mode
  (service `pesa`) avoids that but re-introduces the per-launch access prompt
  under an ad-hoc signature. The old Keychain item
  (`provider-cost-controller`/`openrouter`) still exists until deleted.
- Settings moved from `~/Library/Application Support/ProviderCostController/`,
  so an existing config and Keychain key are not migrated; re-enter the key.

## Recent Noise (ignored this run)

- Static-analysis warnings on the workspace state, not on this change.
- README documents every new setting; no drift remaining.

---
Run log: `docs/superpowers/plans/2026-09-28-harness-registry-provider-details.md`
