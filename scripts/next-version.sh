#!/usr/bin/env bash
# Print the next semantic version (no leading "v") derived from the Conventional
# Commits since the latest vX.Y.Z tag, or print nothing when none of them
# warrants a release.
#
#   feat!: / BREAKING CHANGE:  -> major
#   feat:                      -> minor
#   fix: / perf:               -> patch
#   anything else              -> no release
#
# With no tag yet the first release is 0.1.0. Runs in the current git repo.
set -euo pipefail

# Highest plain vX.Y.Z tag reachable from HEAD; pre-release tags (v1.3.0-rc.1)
# are ignored.
last="$(git tag --merged HEAD --sort=-v:refname | grep -m1 -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
if [ -n "$last" ]; then
  range="$last..HEAD"
  base="${last#v}"
else
  range="HEAD"
  base=""
fi

level=0 # 0 none, 1 patch, 2 minor, 3 major
for sha in $(git rev-list "$range"); do
  subject="$(git log -1 --format=%s "$sha")"
  body="$(git log -1 --format=%b "$sha")"
  if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: ]] ||
     grep -qE '^BREAKING[ -]CHANGE:' <<<"$body"; then
    level=3
  elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
    [ "$level" -lt 2 ] && level=2
  elif [[ "$subject" =~ ^(fix|perf)(\([^\)]*\))?: ]]; then
    [ "$level" -lt 1 ] && level=1
  fi
done

[ "$level" -eq 0 ] && exit 0

if [ -z "$base" ]; then
  echo "0.1.0"
  exit 0
fi

IFS=. read -r major minor patch <<<"$base"
case "$level" in
  3) echo "$((major + 1)).0.0" ;;
  2) echo "$major.$((minor + 1)).0" ;;
  1) echo "$major.$minor.$((patch + 1))" ;;
esac
