#!/usr/bin/env bash
# The one procedure for the binary size (F7b): the shared library
# (`libzregex.so`, the C API) built in ReleaseFast and ReleaseSmall for
# x86_64-linux with a fixed CPU model (x86_64_v3), stripped, then its total
# size, its main sections and its exported `zregex_*` symbols. The CPU is
# fixed because `native` follows the host's CPU features: the same commit
# measured 1,112,272 B and 1,138,656 B (ReleaseFast) on two hosts of this
# container (docs/KNOWN_LIMITATIONS.md). Figures measured some other way
# (native CPU, unstripped, another artifact) aren't comparable with these.
#
#   scripts/measure_binary.sh            the working tree
#   scripts/measure_binary.sh --rev REV  a commit, built in a temporary
#                                        worktree that is removed afterwards
#
# Output: one line per optimize mode,
#   <label> <mode> total=<B> text=<B> rodata=<B> data.rel.ro=<B> symbols=<n>
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
rev=""
if [ "${1:-}" = "--rev" ]; then rev=${2:?usage: measure_binary.sh [--rev REV]}; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; if [ -n "$rev" ]; then git -C "$root" worktree remove --force "$tmp/src" 2>/dev/null || true; git -C "$root" worktree prune; fi' EXIT
if [ -n "$rev" ]; then
  git -C "$root" worktree add -q --detach "$tmp/src" "$rev"
  src=$tmp/src
  label=$(git -C "$root" rev-parse --short "$rev")
else
  src=$root
  label=worktree
fi
for mode in ReleaseFast ReleaseSmall; do
  (cd "$src" && zig build -Doptimize="$mode" -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3 --prefix "$tmp/$mode" >/dev/null)
  so=$(ls "$tmp/$mode"/lib/libzregex.so.* | sort | tail -1)
  cp "$so" "$tmp/stripped.so"
  strip "$tmp/stripped.so"
  sec() { size -A "$tmp/stripped.so" | awk -v s="$1" '$1 == s { print $2 }'; }
  syms=$(nm -D --defined-only "$tmp/stripped.so" | grep -c ' T zregex_' || true)
  echo "$label $mode total=$(stat -c %s "$tmp/stripped.so") text=$(sec .text) rodata=$(sec .rodata) data.rel.ro=$(sec .data.rel.ro) symbols=$syms"
done
