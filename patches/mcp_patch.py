#!/usr/bin/env python3
"""Patch dashboard McpPage-*.js so ALL http-transport MCP servers show the
"Authenticate" button (not just those with auth:oauth explicitly configured).

Rewrites the JSX conditional:
    BEFORE:  e.auth===`oauth`&&(0,X.jsx)(Y,{ghost:!0,size:`sm`,title:`Authenticate with OAuth`
    AFTER:   e.transport===`http`&&(0,X.jsx)(Y,{ghost:!0,size:`sm`,title:`Authenticate with OAuth`

Where X/Y are single-letter minified variable names (typically b/g) — the
regex handles any Vite build's minification.

CRITICAL: this patch is IN-PLACE — it does NOT rename the chunk file.
An earlier version copied the file to `index-OAuthFix{ts}.js` and rewrote
`index.html` to reference the new name; that broke React because Vite's
code-splitting chunks (usePageHeader-*.js etc.) `import` from the
ORIGINAL bundle filename hard-coded at build time. The dual instances
caused a React context singleton mismatch → the whole dashboard SPA
rendered a blank root div.

Idempotent: if the old pattern is no longer present, the script exits
without touching the file.

Usage:
    /opt/hermes/.venv/bin/python3 /opt/data/mcp_patch.py
"""
from __future__ import annotations

import glob
import re
import sys


ASSETS_GLOB = "/opt/hermes/hermes_cli/web_dist/assets/McpPage-*.js"

# Match the button visibility condition. Captures the JSX tail so we can
# preserve minified names (X.jsx, component ref, options object).
PATTERN = re.compile(
    r"e\.auth===`oauth`"
    r"(&&\(0,[a-z]\.jsx\)\([a-z],\{ghost:!0,size:`sm`,title:`Authenticate with OAuth`)"
)
REPLACEMENT = r"e.transport===`http`\1"


def patch_file(path: str) -> int:
    with open(path) as f:
        content = f.read()
    if "e.auth===`oauth`" not in content:
        # Already patched, or upstream Vite build changed the condition.
        return 0
    new_content, n = PATTERN.subn(REPLACEMENT, content)
    if n == 0:
        # Old pattern present but our regex missed — bundle format changed.
        print(
            f"WARN: {path}: 'e.auth===`oauth`' found but PATTERN did not match "
            "(minifier changed?). Skipping.",
            file=sys.stderr,
        )
        return 0
    with open(path, "w") as f:
        f.write(new_content)
    return n


def main() -> int:
    files = glob.glob(ASSETS_GLOB)
    if not files:
        print(f"mcp_patch: no files matched {ASSETS_GLOB}", file=sys.stderr)
        return 1
    total = 0
    for fp in files:
        n = patch_file(fp)
        if n:
            print(f"mcp_patch: {fp} → {n} occurrence(s) rewritten")
            total += n
    if total == 0:
        print("mcp_patch: nothing to do (already patched or pattern absent)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
