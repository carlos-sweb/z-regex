#!/bin/bash
# Builds every harness and the corpora of the cross-engine benchmark, before
# any measurement (nothing is compiled while run.mjs runs).
# Needs: Zig 0.17, Zig 0.16 via ZIG016 for pinned competitors, Node, cargo,
# a C compiler and libpcre2-8 (with JIT).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=zig-out/xbench
node bench/compare/gen_corpus.mjs "$out/corpus"
bash bench/compare/fetch_book.sh "$out/corpus"
zig build xbench -Dcpu=x86_64_v3                    # zig-out/bin/zregex_xbench
(cd bench/compare/rust && cargo build --release -q) # rust_xbench
mkdir -p "$out/bin"
cc -O2 -Wall -o "$out/bin/pcre2_xbench" bench/compare/pcre2_xbench.c -lpcre2-8
# These pinned competitors still require Zig 0.16. Set its executable explicitly.
benchmark_zig016=${ZIG016:-zig}
if [ "$("$benchmark_zig016" version)" != "0.16.0" ]; then
  echo "Set ZIG016 to the Zig 0.16.0 executable for the pinned competitors." >&2
  exit 1
fi
benchmark_zig016_path=$(command -v "$benchmark_zig016")
benchmark_zig016_dir=$(dirname "$benchmark_zig016_path")
PATH="$benchmark_zig016_dir:$PATH" bash bench/compare/setup_zigregex.sh "$out/zigregex"
PATH="$benchmark_zig016_dir:$PATH" bash bench/compare/setup_zoptia.sh "$out/zoptia"
echo "prepared: corpora in $out/corpus, harnesses built"
