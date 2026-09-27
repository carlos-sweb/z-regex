#!/bin/bash
# The realistic corpus of the cross-engine benchmark: "Pride and Prejudice"
# (Project Gutenberg #1342, public domain), from GITenberg's mirror at a
# pinned commit, checked by sha256. Usage: fetch_book.sh OUT_DIR
set -euo pipefail
out=${1:?usage: fetch_book.sh OUT_DIR}
commit=81db45c9c48c592f0b77f01fc59e677ad0a5634e
sha=48e0522844402a86a3ea98f0947ba85ea54838db3c59022299298ed968a5a163
mkdir -p "$out"
if [ ! -f "$out/book.txt" ]; then
  tmp=$(mktemp -d)
  git clone -q https://github.com/GITenberg/Pride-and-Prejudice_1342 "$tmp/pp"
  git -C "$tmp/pp" checkout -q "$commit"
  cp "$tmp/pp/1342-0.txt" "$out/book.txt"
  rm -rf "$tmp"
fi
echo "$sha  $out/book.txt" | sha256sum -c --quiet
echo "book: $out/book.txt ($(wc -c < "$out/book.txt") bytes, sha256 ok)"
