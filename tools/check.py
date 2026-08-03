#!/usr/bin/env python3
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the
# Mochi Application Interface Exception - see license.txt and license-exception.md.

"""The checks this repo can run on its own. The library's behavioural suite
needs a running server and lives with the platform (apps/test drives every
function, and claude/scripts/p2p-test.py drives the P2P paths end to end);
what a standalone checkout can still catch at PR time is the
bracket-and-indent class of break, a name defined twice, and a module-level
name used before the line that defines it - Starlark resolves at call time,
so that last one is legal at runtime and still makes the file read backwards.

Starlark is syntactically a Python subset and these files stay inside the
overlap, so Python's own parser is the syntax gate."""
import ast
import sys
from pathlib import Path


def check(path):
    failures = []
    source = path.read_text(encoding="utf-8")
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as error:
        return [f"{path}:{error.lineno}: syntax: {error.msg}"]

    seen = {}
    for node in tree.body:
        names = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            names = [node.name]
        elif isinstance(node, ast.Assign):
            names = [target.id for target in node.targets if isinstance(target, ast.Name)]
        for name in names:
            if name in seen:
                failures.append(f"{path}:{node.lineno}: {name} already defined at line {seen[name]}")
            seen[name] = node.lineno

    # A module-level constant read by a module-level expression before its
    # definition line. Function bodies are exempt: they run after the whole
    # file has loaded.
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for used in ast.walk(node.value):
                if isinstance(used, ast.Name) and isinstance(used.ctx, ast.Load):
                    if used.id in seen and seen[used.id] > node.lineno:
                        failures.append(
                            f"{path}:{node.lineno}: {used.id} used before its definition at line {seen[used.id]}")
    return failures


def main():
    root = Path(__file__).resolve().parent.parent
    files = sorted(root.glob("*.star"))
    if not files:
        print("no .star files found", file=sys.stderr)
        sys.exit(1)
    failures = []
    for path in files:
        failures += check(path)
    for failure in failures:
        print(failure)
    if failures:
        sys.exit(1)
    print(f"checked {len(files)} file(s): clean")


if __name__ == "__main__":
    main()
