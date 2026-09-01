#!/usr/bin/env python3
"""tests/extract_fn.py - extract a bash function by name (brace-aware).

Usage: python3 tests/extract_fn.py <file> <funcname>

Unlike `sed -n '/^fn()/,/^}/p'`, this handles nested braces (functions,
`{ ... }` blocks) and ignores braces inside strings and comments. Brace
expansions like `{c..z}` are balanced, so they do not break the depth count.
"""
import re
import sys


def extract(path: str, name: str) -> str:
    src = open(path, encoding="utf-8").read()
    m = re.search(r"^%s\(\)\s*\{" % re.escape(name), src, re.M)
    if not m:
        sys.exit(2)
    depth = 0
    in_str = None
    in_comment = False
    j = m.end() - 1  # position of the opening '{'
    while j < len(src):
        c = src[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == in_str:
                in_str = None
        elif in_comment:
            if c == "\n":
                in_comment = False
        else:
            if c in "'\"":
                in_str = c
            elif c == "#":
                in_comment = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return src[m.start():j + 1]
        j += 1
    sys.exit(3)


if __name__ == "__main__":
    print(extract(sys.argv[1], sys.argv[2]))
