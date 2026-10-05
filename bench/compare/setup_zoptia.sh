#!/bin/bash
# Builds the zoptia/zoptia0regex harness of the cross-engine benchmark: a Zig
# port of Go's regexp, at a pinned commit (the repository has no tags), with
# the CPU model of z-regex's harness (x86_64_v3). Its code is untouched.
# Usage: setup_zoptia.sh WORK_DIR   (binary: WORK_DIR/zoptia_xbench)
set -euo pipefail
work=${1:?usage: setup_zoptia.sh WORK_DIR}
here=$(cd "$(dirname "$0")" && pwd)
commit=8e8f2256e475ff62902586346640876871768a5d
mkdir -p "$work"
if [ ! -d "$work/zoptia0regex" ]; then
  git clone -q https://github.com/zoptia/zoptia0regex "$work/zoptia0regex"
fi
git -C "$work/zoptia0regex" checkout -q "$commit"
zig build-exe -OReleaseFast -mcpu=x86_64_v3 --dep regex -Mroot="$here/zoptia_xbench.zig" \
  -OReleaseFast -mcpu=x86_64_v3 -Mregex="$work/zoptia0regex/src/root.zig" \
  -femit-bin="$work/zoptia_xbench"
echo "built $work/zoptia_xbench (zoptia0regex ${commit:0:7})"
