#!/usr/bin/env bash
# Fetch the pinned test262 revision the zregex harness runs against.
# Shallow + sparse: only the RegExp directories and the full harness/.
set -euo pipefail

SHA="$(cat "$(dirname "$0")/TEST262_SHA")"
DEST="${1:-$(cd "$(dirname "$0")/../.." && pwd)/.test262}"

if [ ! -d "$DEST/.git" ]; then
  git init -q "$DEST"
  git -C "$DEST" remote add origin https://github.com/tc39/test262.git
fi
git -C "$DEST" sparse-checkout set --no-cone \
  /harness/ \
  /test/built-ins/RegExp/ \
  /test/language/literals/regexp/ \
  /test/annexB/built-ins/RegExp/ \
  /test/annexB/language/literals/regexp/
git -C "$DEST" fetch -q --depth 1 origin "$SHA"
git -C "$DEST" checkout -q --detach FETCH_HEAD
echo "test262 $(git -C "$DEST" rev-parse HEAD) -> $DEST"
