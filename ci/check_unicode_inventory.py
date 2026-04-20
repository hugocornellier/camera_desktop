#!/usr/bin/env python3
"""Assert that every non-ASCII character appearing in windows/*.cpp|*.h also
appears in ci/cp936_repro.cpp.

Purpose: the CP936 simulation step in CI compiles cp936_repro.cpp to prove that
/utf-8 resolves C4819 for the exact character set we use. If a new file adds a
new Unicode character (e.g. a µ in a comment) without updating the synthetic
repro, CI would silently keep passing while real Simplified-Chinese Windows
hosts would start failing again.

Run from the repo root. Exits non-zero with a clear message if drift is found.
"""

from __future__ import annotations

import pathlib
import sys


def non_ascii_chars(path: pathlib.Path) -> set[str]:
    return {c for c in path.read_text(encoding="utf-8") if ord(c) > 0x7F}


def main() -> int:
    windows_sources = sorted(
        list(pathlib.Path("windows").glob("*.cpp"))
        + list(pathlib.Path("windows").glob("*.h"))
    )
    if not windows_sources:
        print("::error::No windows/*.cpp|*.h files found — run from repo root.")
        return 1

    real: set[str] = set()
    per_file: dict[str, set[str]] = {}
    for f in windows_sources:
        chars = non_ascii_chars(f)
        if chars:
            per_file[str(f)] = chars
        real |= chars

    synthetic_path = pathlib.Path("ci/cp936_repro.cpp")
    if not synthetic_path.exists():
        print(f"::error::{synthetic_path} missing.")
        return 1

    synthetic = non_ascii_chars(synthetic_path)

    missing = real - synthetic
    if missing:
        print("::error::ci/cp936_repro.cpp is missing characters used in windows/ sources.")
        print("Missing:")
        for c in sorted(missing):
            sources = [f for f, cs in per_file.items() if c in cs]
            print(f"  U+{ord(c):04X}  {c!r}  (in: {', '.join(sources)})")
        print()
        print("Fix: add these characters to ci/cp936_repro.cpp so the CP936 CI")
        print("simulation stays representative of the real sources.")
        return 1

    print(f"OK: all {len(real)} non-ASCII chars in windows/ are covered by {synthetic_path}.")
    for c in sorted(real):
        print(f"  U+{ord(c):04X}  {c}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
