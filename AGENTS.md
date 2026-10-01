# AGENTS.md

Conventions for agents working in this repo — the **Pesa** macOS menu-bar app
(Swift, Command Line Tools only: no Xcode project, no SwiftPM, no XCTest).

## Build & test

```sh
./scripts/build.sh          # swiftc -> .build/Pesa
./.build/Pesa --selftest    # assert-based suite; exits 0 on success
./scripts/build-app.sh      # assemble + sign Pesa.app
./scripts/package-app.sh    # zip + dmg under dist/
```

## Safety

- Never push or merge without human approval.
- Never edit `.env`, `.env.*`, `auth/`, `payments/`, `secrets/`, or
  `credentials/`, or any real tool config under `~/.pi`, `~/.config/opencode`,
  `~/.hermes`, or `~/.pesa-app`. The selftest uses temp-dir fixtures only.
- Use a git worktree for every code-changing attempt.
- Max 3 fix attempts per item; escalate after that.

## Verification

- Run `./scripts/build.sh` and `./.build/Pesa --selftest` before proposing a
  change; every check must pass.
- For source changes, dispatch an independent verifier sub-agent after
  implementation (it must try to reject, not confirm).
- Report exact evidence: exit codes and PASS/FAIL counts.
