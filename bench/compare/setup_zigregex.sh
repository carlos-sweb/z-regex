#!/bin/bash
# Builds the zig-utils/zig-regex harness of the cross-engine benchmark.
# v0.1.1 (pinned commit) is the last release that builds with Zig 0.16
# (v0.2.x needs 0.17-dev). Its build.zig.zon gets two metadata fixes for
# 0.16 (package name as a bare identifier, and the fingerprint 0.16 then
# asks for); its code is untouched.
# Usage: setup_zigregex.sh WORK_DIR   (binary: WORK_DIR/zigregex_xbench)
set -euo pipefail
work=${1:?usage: setup_zigregex.sh WORK_DIR}
here=$(cd "$(dirname "$0")" && pwd)
commit=173b2985311f7efeb08fbd34ced82faef9598b24
mkdir -p "$work"
if [ ! -d "$work/zig-regex" ]; then
  git clone -q https://github.com/zig-utils/zig-regex "$work/zig-regex"
fi
git -C "$work/zig-regex" checkout -q "$commit"
sed -i 's/\.name = \.@"zig-regex",/.name = .zig_regex,/; s/0x4204f8ca194fd46e/0x7bcf21eb515113b8/' "$work/zig-regex/build.zig.zon"
zig build-exe -OReleaseFast --dep regex -Mroot="$here/zigregex_xbench.zig" \
  -OReleaseFast -Mregex="$work/zig-regex/src/root.zig" \
  -femit-bin="$work/zigregex_xbench"
echo "built $work/zigregex_xbench (zig-regex $(git -C "$work/zig-regex" describe --tags))"
