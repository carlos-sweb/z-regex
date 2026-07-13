#!/usr/bin/env python3
"""Heuristic extractor: pulls simple, verifiable regex test cases out of
test262's RegExp test files (which are full JS programs, not declarative
data). Only recognizes a handful of common simple shapes; everything else
is honestly counted as "skipped", not silently ignored.
"""
import json
import os
import re
import sys

ROOT = "test"
SKIP_DIR_SUBSTRINGS = [
    "property-escapes",  # \p{...} - not implemented, out of scope
    "Symbol.replace", "Symbol.split", "Symbol.match", "Symbol.matchAll",
    "Symbol.species",
]

FRONTMATTER_RE = re.compile(r"/\*---(.*?)---\*/", re.DOTALL)
FEATURES_RE = re.compile(r"features:\s*\[([^\]]*)\]")
NEGATIVE_RE = re.compile(r"negative:")

UNSUPPORTED_FEATURES = {
    "regexp-unicode-property-escapes", "regexp-v-flag", "regexp-match-indices",
    "regexp-duplicate-named-groups", "regexp-modifiers", "regexp-lookbehind",
    "regexp-named-groups",  # named groups ARE supported, but skip for now to
                             # keep the __expected.groups shape out of scope
}

JS_STRING_BODY = r'(?:\\.|[^"\\])*'
JS_STRING = r'"(' + JS_STRING_BODY + r')"'
IDENT = r'[A-Za-z_$][A-Za-z0-9_$]*'
REGEX_LITERAL = r'/((?:\\.|\[(?:\\.|[^\]])*\]|[^/\\\n])+)/([a-z]*)'

PAT_TEST_ASSERT = re.compile(r'assert\(\s*' + REGEX_LITERAL + r'\.test\(' + JS_STRING + r'\)\s*\)')
PAT_TEST_ASSERT_NEG = re.compile(r'assert\(\s*!\s*' + REGEX_LITERAL + r'\.test\(' + JS_STRING + r'\)\s*\)')
PAT_TEST_SAMEVALUE = re.compile(
    r'assert\.sameValue\(\s*' + REGEX_LITERAL + r'\.test\(' + JS_STRING + r'\)\s*,\s*(true|false)\s*[,)]'
)
PAT_EXEC_SAMEVALUE_NULL = re.compile(
    r'assert\.sameValue\(\s*' + REGEX_LITERAL + r'\.exec\(' + JS_STRING + r'\)\s*,\s*null\s*[,)]'
)

VAR_STRING_ASSIGN = re.compile(r'var\s+(' + IDENT + r')\s*=\s*' + JS_STRING + r'\s*;')
EXEC_ASSIGN = re.compile(
    r'var\s+' + IDENT + r'\s*=\s*' + REGEX_LITERAL + r'\.exec\(\s*(?:' + JS_STRING + r'|(' + IDENT + r'))\s*\)\s*;'
)
EXPECTED_ARRAY = re.compile(r'var\s+' + IDENT + r'\s*=\s*\[([^\]]*)\]\s*;')
ARRAY_ITEM = re.compile(r'\s*(?:' + JS_STRING + r'|undefined|void 0)\s*(?:,|$)')


def decode_js_string(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            nc = s[i + 1]
            if nc == "n": out.append("\n"); i += 2
            elif nc == "t": out.append("\t"); i += 2
            elif nc == "r": out.append("\r"); i += 2
            elif nc == "b": out.append("\b"); i += 2
            elif nc == "f": out.append("\f"); i += 2
            elif nc == "v": out.append("\v"); i += 2
            elif nc == "\\": out.append("\\"); i += 2
            elif nc == '"': out.append('"'); i += 2
            elif nc == "'": out.append("'"); i += 2
            elif nc == "0" and (i + 2 >= len(s) or not s[i + 2].isdigit()):
                out.append("\x00"); i += 2
            elif nc == "u":
                if i + 2 < len(s) and s[i + 2] == "{":
                    end = s.index("}", i + 3)
                    out.append(chr(int(s[i + 3:end], 16))); i = end + 1
                else:
                    out.append(chr(int(s[i + 2:i + 6], 16))); i += 6
            elif nc == "x":
                out.append(chr(int(s[i + 2:i + 4], 16))); i += 4
            else:
                out.append(nc); i += 2
        else:
            out.append(c); i += 1
    return "".join(out)


def parse_array_items(body):
    """Parse a restricted JS array-literal body: comma-separated string
    literals / undefined / void 0. Returns None if anything else appears."""
    items = []
    pos = 0
    body = body.strip()
    if body == "":
        return items
    parts = []
    depth = 0
    cur = ""
    i = 0
    while i < len(body):
        c = body[i]
        if c == '"' and (i == 0 or body[i - 1] != "\\"):
            j = i + 1
            while j < len(body) and not (body[j] == '"' and body[j - 1] != "\\"):
                j += 1
            cur += body[i:j + 1]
            i = j + 1
            continue
        if c == ",":
            parts.append(cur)
            cur = ""
            i += 1
            continue
        cur += c
        i += 1
    parts.append(cur)
    for p in parts:
        p = p.strip()
        if p == "" and len(parts) == 1:
            continue
        if p == "undefined" or p == "void 0":
            items.append(None)
        elif p.startswith('"') and p.endswith('"') and len(p) >= 2:
            items.append(decode_js_string(p[1:-1]))
        else:
            return None  # unrecognized item shape, bail
    return items


def should_skip_path(path):
    return any(s in path for s in SKIP_DIR_SUBSTRINGS)


def parse_frontmatter(src):
    m = FRONTMATTER_RE.search(src)
    if not m:
        return set(), False
    fm = m.group(1)
    features = set()
    fmatch = FEATURES_RE.search(fm)
    if fmatch:
        features = {f.strip() for f in fmatch.group(1).split(",") if f.strip()}
    is_negative = bool(NEGATIVE_RE.search(fm))
    return features, is_negative


def extract_simple(src):
    cases = []
    for m in PAT_TEST_ASSERT_NEG.finditer(src):
        pattern, flags, s = m.groups()
        cases.append({"kind": "test", "pattern": pattern, "flags": flags,
                      "input": decode_js_string(s), "expected": False})
    for m in PAT_TEST_ASSERT.finditer(src):
        pattern, flags, s = m.groups()
        cases.append({"kind": "test", "pattern": pattern, "flags": flags,
                      "input": decode_js_string(s), "expected": True})
    for m in PAT_TEST_SAMEVALUE.finditer(src):
        pattern, flags, s, expected = m.groups()
        cases.append({"kind": "test", "pattern": pattern, "flags": flags,
                      "input": decode_js_string(s), "expected": expected == "true"})
    for m in PAT_EXEC_SAMEVALUE_NULL.finditer(src):
        pattern, flags, s = m.groups()
        cases.append({"kind": "exec_null", "pattern": pattern, "flags": flags,
                      "input": decode_js_string(s), "expected": None})
    return cases


def extract_exec_array(src):
    """Pattern A: var X = /pat/flags.exec(STR|IDENT); var Y = [items...];"""
    cases = []
    string_vars = {m.group(1): decode_js_string(m.group(2)) for m in VAR_STRING_ASSIGN.finditer(src)}

    for m in EXEC_ASSIGN.finditer(src):
        pattern, flags, lit, ident = m.groups()
        if lit is not None:
            input_str = decode_js_string(lit)
        elif ident is not None:
            if ident not in string_vars:
                continue
            input_str = string_vars[ident]
        else:
            continue

        # Look for the very next "var NAME = [...]" after this match's end
        rest = src[m.end():m.end() + 500]
        am = EXPECTED_ARRAY.search(rest)
        if not am or am.start() > 200:
            continue
        items = parse_array_items(am.group(1))
        if items is None:
            continue
        cases.append({"kind": "exec_array", "pattern": pattern, "flags": flags,
                      "input": input_str, "expected": items})
    return cases


def main():
    total_files = 0
    skipped_dir = 0
    skipped_features = 0
    skipped_negative = 0
    skipped_no_match = 0
    extracted_files = 0
    all_cases = []

    for dirpath, _, filenames in os.walk(ROOT):
        for fn in filenames:
            if not fn.endswith(".js") or fn.endswith("_FIXTURE.js"):
                continue
            path = os.path.join(dirpath, fn)
            total_files += 1
            if should_skip_path(path):
                skipped_dir += 1
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()

            features, is_negative = parse_frontmatter(src)
            if features & UNSUPPORTED_FEATURES:
                skipped_features += 1
                continue
            if is_negative:
                skipped_negative += 1
                continue

            cases = extract_simple(src) + extract_exec_array(src)
            cases = [c for c in cases if "u" not in c["flags"] and "v" not in c["flags"]]
            if not cases:
                skipped_no_match += 1
                continue
            extracted_files += 1
            for c in cases:
                c["file"] = os.path.relpath(path, ROOT)
                all_cases.append(c)

    print(f"Total .js files scanned: {total_files}", file=sys.stderr)
    print(f"Skipped (out-of-scope dir): {skipped_dir}", file=sys.stderr)
    print(f"Skipped (unsupported feature tag): {skipped_features}", file=sys.stderr)
    print(f"Skipped (negative/syntax-error test): {skipped_negative}", file=sys.stderr)
    print(f"Skipped (no recognized simple pattern): {skipped_no_match}", file=sys.stderr)
    print(f"Files with >=1 extracted case: {extracted_files}", file=sys.stderr)
    print(f"Total extracted cases: {len(all_cases)}", file=sys.stderr)

    json.dump(all_cases, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
