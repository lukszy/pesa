#!/usr/bin/env bash
# Tests for scripts/next-version.sh using throwaway git repos in a temp dir.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/next-version.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

new_repo() {
  rm -rf "$WORK/r" && mkdir "$WORK/r" && cd "$WORK/r"
  git init -q
  git config user.email t@t && git config user.name t && git config commit.gpgsign false
}
commit() { git commit -q --allow-empty -m "$1"; }
check() { # name expected
  local got
  got="$("$SCRIPT")"
  if [ "$got" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1: want '$2' got '$got'"; fails=$((fails + 1)); fi
}

new_repo; commit "feat: first";                          check "no tag, feat -> 0.1.0" "0.1.0"
new_repo; commit "docs: only";                           check "no tag, docs -> none" ""
new_repo; commit "chore: x"; git tag v1.2.3; commit "docs: y"; check "tag, docs only -> none" ""
new_repo; commit "x"; git tag v1.2.3; commit "fix(ui): y"; check "fix -> patch" "1.2.4"
new_repo; commit "x"; git tag v1.2.3; commit "perf: y";    check "perf -> patch" "1.2.4"
new_repo; commit "x"; git tag v1.2.3; commit "fix: a"; commit "feat(editor): b"; check "feat beats fix -> minor" "1.3.0"
new_repo; commit "x"; git tag v1.2.3; commit "feat!: a";   check "bang -> major" "2.0.0"
new_repo; commit "x"; git tag v1.2.3; commit "fix: a

BREAKING CHANGE: gone"; check "footer -> major" "2.0.0"
new_repo; commit "feat: old"; git tag v0.1.0; commit "ci: z"; check "commits before tag ignored" ""
new_repo; commit "x"; git tag v1.2.3; git tag v1.3.0-rc.1; commit "fix: z"; check "pre-release tag ignored" "1.2.4"
new_repo; commit "x"; git tag v1.2.9; git tag v1.2.10; commit "fix: z"; check "version sort, not lexical" "1.2.11"
new_repo; commit "x"; git tag v1.2.3; commit "Feat!: a"; check "uppercase type ignored" ""

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
