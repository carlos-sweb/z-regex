#!/bin/bash
# Builds every harness and the corpora of the cross-engine benchmark, before
# any measurement (nothing is compiled while run.mjs runs).
# Needs: Zig 0.16, Node, cargo, a C compiler and libpcre2-8 (with JIT).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=zig-out/xbench
node bench/compare/gen_corpus.mjs "$out/corpus"
bash bench/compare/fetch_book.sh "$out/corpus"
zig build xbench                                   # zig-out/bin/zregex_xbench
(cd bench/compare/rust && cargo build --release -q) # rust_xbench
mkdir -p "$out/bin"
cc -O2 -Wall -o "$out/bin/pcre2_xbench" bench/compare/pcre2_xbench.c -lpcre2-8
bash bench/compare/setup_zigregex.sh "$out/zigregex"
bash bench/compare/setup_zoptia.sh "$out/zoptia"
echo "prepared: corpora in $out/corpus, harnesses built"
