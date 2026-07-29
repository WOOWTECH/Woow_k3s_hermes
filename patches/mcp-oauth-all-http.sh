#!/bin/bash
# MCP OAuth Button Patch — Show Authenticate for ALL HTTP MCP servers
#
# What: Patches the compiled Dashboard React SPA so the "Authenticate with
#       OAuth" button appears next to EVERY HTTP-transport MCP server
#       (not just those with auth:oauth explicitly configured).
#
# When: Run after any pod restart that resets the image layer. If you
#       call `mcp_patch.py` from the agent's postStart hook, this manual
#       step is unnecessary.
#
# How:  Copies patches/mcp_patch.py into the pod's PVC-backed /opt/data
#       and executes it. The Python patch:
#         BEFORE: e.auth===`oauth`&&(0,X.jsx)(Y,{...title:`Authenticate with OAuth`
#         AFTER:  e.transport===`http`&&(0,X.jsx)(Y,{...title:`Authenticate with OAuth`
#       It targets McpPage-*.js (a code-split chunk), NOT index-*.js.
#
# Prior-version bugs (fixed 2026-07-29):
#   1. Targeted index-*.js (wrong file — button code is code-split to McpPage-*.js)
#   2. Used minified names `W` and `G` — upstream Vite build now emits `b`/`g`
#      so sed matched 0 lines (silent no-op)
#   3. Copied bundle to index-OAuthFix{ts}.js and rewrote index.html →
#      BROKE the whole dashboard SPA because Vite's other chunks
#      (usePageHeader-*.js etc.) still import from the ORIGINAL bundle
#      filename, causing a React context singleton mismatch and a blank
#      root div.
#
# The new version does NOT rename the chunk file — it patches in place.
#
# Cache note: /assets/*.js has Cache-Control: max-age=14400 (4h). After
# running this, users must hard-refresh their browser (Ctrl+Shift+R) to
# see the change until the cache expires.
#
# Usage:
#   ./patches/mcp-oauth-all-http.sh [KUBE_CONTEXT] [NAMESPACE]
# Defaults: KUBE_CONTEXT=woow-k3s NAMESPACE=hermes

set -euo pipefail

CONTEXT="${1:-woow-k3s}"
NS="${2:-hermes}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_PATCH="${SCRIPT_DIR}/mcp_patch.py"

[ -f "$PY_PATCH" ] || {
  echo "ERROR: $PY_PATCH not found (expected sibling of this script)" >&2
  exit 1
}

KC="kubectl --context ${CONTEXT} -n ${NS}"
POD=$($KC get pod -l app=hermes -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "ERROR: no pod with label app=hermes in ns=${NS}" >&2; exit 1; }
echo "Pod: ${POD}"

# 1. Copy patch script into pod's PVC so it survives image restarts.
echo "Uploading mcp_patch.py to /opt/data/mcp_patch.py ..."
$KC cp "$PY_PATCH" "${POD}:/opt/data/mcp_patch.py" -c hermes-agent
$KC exec "$POD" -c hermes-agent -- chmod +x /opt/data/mcp_patch.py

# 2. Execute the patch.
echo "Running patch ..."
$KC exec "$POD" -c hermes-agent -- /opt/hermes/.venv/bin/python3 /opt/data/mcp_patch.py

# 3. Verify.
echo ""
echo "Verification:"
$KC exec "$POD" -c hermes-agent -- sh -c '
  MP=$(ls /opt/hermes/hermes_cli/web_dist/assets/McpPage-*.js | head -1)
  OLD=$(grep -c "e\.auth===\`oauth\`" "$MP" || true)
  NEW=$(grep -oE "e\.transport===\`http\`&&\(0,[a-z]\.jsx\)\([a-z],\{ghost.{0,60}Authenticate with OAuth" "$MP" | wc -l)
  echo "  file: $MP"
  echo "  old pattern (e.auth===\`oauth\`) remaining: $OLD  (want 0)"
  echo "  new pattern (e.transport===\`http\`+button):  $NEW  (want 1)"
  [ "$OLD" = "0" ] && [ "$NEW" = "1" ] && echo "  ✅ Patch applied" || echo "  ❌ Patch verification failed"
'
echo ""
echo "Next: hard-refresh the Dashboard (Ctrl+Shift+R) to bust the browser cache."
