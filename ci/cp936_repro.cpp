// Synthetic CP936-reproduction file for CI.
//
// This file deliberately contains every non-ASCII character that appears in
// windows/*.cpp and windows/*.h, so that compiling it with
//   cl /c /WX /source-charset:.936 /execution-charset:.936
// reproduces the exact C4819 / C2220 failure that users see on Simplified
// Chinese Windows hosts (where GetACP() == 936 / GBK).
//
// DO NOT add a BOM to this file. With a BOM, MSVC auto-detects UTF-8 and
// ignores /source-charset:.936, which would defeat the test.
//
// If you add a new non-ASCII character anywhere under windows/, the CI step
// `ci/check_unicode_inventory.py` will fail until you add that character
// here. Keep the inventory below in sync.
//
// Covered characters (also listed explicitly so a byte-level grep for the
// UTF-8 sequences finds them here):
//   U+2026 HORIZONTAL ELLIPSIS          …
//   U+2192 RIGHTWARDS ARROW             →
//   U+2194 LEFT RIGHT ARROW             ↔
//   U+2264 LESS-THAN OR EQUAL TO        ≤
//   U+2500 BOX DRAWINGS LIGHT HORIZONTAL ─
//
// No code needed: /c (compile only) is sufficient to trigger C4819 on the
// comment bytes above.
