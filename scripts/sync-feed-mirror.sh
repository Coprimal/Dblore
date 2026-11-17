#!/bin/bash

# Copy the published appcast to the old-feed mirror.
#
# Builds <= 0.10.1 read their Sparkle feed from
# https://dinhanhthi.github.io/Dblore/appcast.xml. After the repo moved to
# Coprimal/Dblore, GitHub no longer serves or redirects that address, so the user
# site dinhanhthi/dinhanhthi.github.io serves a copy at Dblore/appcast.xml.
# release-local.sh runs this script on every release so those builds always see
# the latest version. Never edit the mirror's appcast by hand.
#
# Usage: scripts/sync-feed-mirror.sh [appcast.xml]

set -euo pipefail

MIRROR_REPO="dinhanhthi/dinhanhthi.github.io"
MIRROR_PATH="Dblore/appcast.xml"
SOURCE="${1:-appcast.xml}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$SOURCE" ]] || fail "$SOURCE not found"

current_sha="$(gh api "repos/$MIRROR_REPO/contents/$MIRROR_PATH" --jq .sha)" ||
  fail "cannot read $MIRROR_PATH in $MIRROR_REPO"
local_sha="$(git hash-object "$SOURCE")"

if [[ "$current_sha" == "$local_sha" ]]; then
  echo "mirror already current ($MIRROR_REPO/$MIRROR_PATH)"
  exit 0
fi

version="$(grep -o '<sparkle:shortVersionString>[^<]*' "$SOURCE" | head -1 | sed 's/.*>//' || true)"

# The body goes through stdin: the base64 appcast grows with every release.
base64 <"$SOURCE" | tr -d '\n' |
  jq -Rs --arg message "chore: sync Dblore appcast ${version:-update}" --arg sha "$current_sha" \
    '{message: $message, content: ., sha: $sha}' |
  gh api -X PUT "repos/$MIRROR_REPO/contents/$MIRROR_PATH" --input - --jq .commit.sha >/dev/null ||
  fail "cannot update $MIRROR_PATH in $MIRROR_REPO"

echo "mirror updated: https://dinhanhthi.github.io/$MIRROR_PATH (${version:-unknown version})"
