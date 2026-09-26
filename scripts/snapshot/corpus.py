#!/usr/bin/env python3
"""Build the corpus of tests/snapshots/bytecode.txt (docs/REGEX_TIERS_PLAN.md, F2b/F2c).

Collects every pattern (with its flags) from tests/test262_data.zig,
tests/syntax_tests.zig and tests/captures_tests.zig and writes one line per
(flags, pattern) with a placeholder outcome. `zig build update-bytecode-snapshot`
then fills in the outcomes (a hash of the compiled program, or the compile
error). Re-run this only to change the corpus; outcomes of patterns already in
the file are kept until the update step recomputes them.

    python3 scripts/snapshot/corpus.py && zig build update-bytecode-snapshot
"""

import json
import os
import re

REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(REPO, 'tests', 'snapshots', 'bytecode.txt')

HEADER = """\
# Bytecode snapshot (docs/REGEX_TIERS_PLAN.md: taken after F2b, checked from F2c on).
# One line per (flags, pattern): outcome, flags, pattern as hex, pattern as JSON (informational).
# outcome = Wyhash of the compiled program (bytecode, then every CharSet of
# CompileResult.charsets in table order), or error:<Name> if compile fails.
# Checked by tests/bytecode_snapshot.zig (zig build test); regenerate outcomes
# with `zig build update-bytecode-snapshot`, the corpus with scripts/snapshot/corpus.py.
#
# Policy on a difference: report it (the test prints the pattern and the new
# program); a length change without a behavior change (reordered SPLIT, an
# omitted Empty, shifted offsets, several CHAR merged into a literal) is
# justified in the commit that updates this file; a semantic change is a bug.
#
# Baseline notes (F2b): classes that don't fit the ASCII bitmap compile to
# CHAR_SET idx:u32 (5 bytes) instead of the fixed-table instructions (up to
# 242 bytes), e.g. `[]` was CHAR_CLASS_RANGES with 0 ranges and is now CHAR_SET
# over an empty table. Shorter bytecode there is expected, not a regression.
"""

FLAG_FIELDS = {'case_insensitive': 'i', 'multiline': 'm', 'dot_all': 's', 'unicode': 'u', 'v': 'v'}


def zig_unescape(lit):
    out = []
    i = 0
    while i < len(lit):
        c = lit[i]
        if c != '\\':
            out.append(c.encode('utf-8'))
            i += 1
            continue
        n = lit[i + 1]
        simple = {'\\': b'\\', '"': b'"', "'": b"'", 'n': b'\n', 't': b'\t', 'r': b'\r'}
        if n in simple:
            out.append(simple[n])
            i += 2
        elif n == 'x':
            out.append(bytes([int(lit[i + 2:i + 4], 16)]))
            i += 4
        elif n == 'u' and lit[i + 2] == '{':
            j = lit.index('}', i)
            out.append(chr(int(lit[i + 3:j], 16)).encode('utf-8', 'surrogatepass'))
            i = j + 1
        else:
            return None
    return b''.join(out)


def norm_flags(s):
    return ''.join(sorted(set(c for c in s if c in 'imsuv')))


def flags_from_options(text):
    return norm_flags(''.join(f for k, f in FLAG_FIELDS.items() if re.search(r'\.' + k + r'\s*=\s*true', text)))


def main():
    entries = []
    seen = set()

    def add(flags, pattern):
        if pattern is None or (flags, pattern) in seen:
            return
        seen.add((flags, pattern))
        entries.append((flags, pattern))

    src = open(os.path.join(REPO, 'tests', 'test262_data.zig'), encoding='utf-8').read()
    for m in re.finditer(r'\.pattern = "((?:[^"\\]|\\.)*)", \.flags = "([^"]*)"', src):
        add(norm_flags(m.group(2)), zig_unescape(m.group(1)))

    # Options in these files are mostly named constants or loop variables;
    # every pattern also goes in without flags and with `u`.
    named = {'annex_b': [''], 'u': ['u'], 'opts': ['', 'u', 'v'], 'm': ['m'], 'dot_all': ['s'], 'poss': ['']}
    call = re.compile(
        r'(?:expectMatch|expectRejected|expectAccepted|compileWithOptions|compile)\(\s*'
        r'(?:[A-Za-z_.]+,\s*)?"((?:[^"\\\n]|\\.)*)"\s*(?:,\s*(\.\{[^}]*\}|[A-Za-z_]+))?')
    for name in ('syntax_tests.zig', 'captures_tests.zig'):
        src = open(os.path.join(REPO, 'tests', name), encoding='utf-8').read()
        for m in call.finditer(src):
            pattern = zig_unescape(m.group(1))
            opt = m.group(2) or ''
            for flags in (named.get(opt) or [flags_from_options(opt)]) + ['', 'u']:
                add(flags, pattern)
        # Patterns listed in arrays and run in a loop.
        for block in re.finditer(r'\[_\]\[\]const u8\{(.*?)\}\)', src, re.S):
            for lit in re.finditer(r'"((?:[^"\\\n]|\\.)*)"', block.group(1)):
                for flags in ('', 'u', 'v'):
                    add(flags, zig_unescape(lit.group(1)))

    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(HEADER)
        for flags, pattern in entries:
            shown = json.dumps(pattern.decode('utf-8', 'backslashreplace'), ensure_ascii=True)[1:-1]
            f.write(f'-\t{flags}\t{pattern.hex()}\t{shown}\n')
    print(f'{len(entries)} entries -> {os.path.relpath(OUT, REPO)}')


if __name__ == '__main__':
    main()
