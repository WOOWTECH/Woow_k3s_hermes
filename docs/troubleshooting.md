# Troubleshooting

Field-notes for known upstream/bundling issues encountered on live deployments.
Fixes here are already wired into `deploy/k3s/manifests/06-hermes.yaml` — this
document exists so operators understand *why* the workarounds are there and
what breaks if they're removed.

> **Historical note.** Sections previously covering WebUI chat failures
> (`dict.model_dump`), `officecli not found in webui`, and the
> "Which chat surface can invoke ffmpeg / edge-tts / rclone / playwright"
> matrix were removed alongside the WebUI sidecar in
> CHANGELOG [0.17.0]. See
> [`docs/migration/2026-07-30-webui-removal.md`](migration/2026-07-30-webui-removal.md)
> for the historical context and the git history for the original text.

---

## 1. Dashboard renders a blank page after loading

**Symptom**
- `https://<host>/sessions` returns valid HTML, but `<div id="root">` never
  populates. Browser console shows
  `usePageHeader must be used within a PageHeaderProvider`
  followed by a cascading
  `NotFoundError: Failed to execute 'removeChild' on 'Node'`.

**Root cause**
The old `patches/mcp-oauth-all-http.sh` copied the built Vite entry chunk
to `index-OAuthFix{timestamp}.js` and rewrote `index.html` to reference the
new filename. But Vite's *other* code-split chunks (e.g.
`usePageHeader-*.js`) `import` from the ORIGINAL bundle filename hard-coded
at build time. Two module instances → React context singleton mismatch →
crash on first `useContext()`.

**Fix**
Never rename the entry chunk. The rewritten `patches/mcp_patch.py` (and
`patches/mcp-oauth-all-http.sh` wrapper) patch the button visibility
condition **in place** in `McpPage-*.js` — no rename, no `index.html`
rewrite. The hermes-agent postStart hook auto-runs the patch script on
every pod restart if it's been copied to `/opt/data/mcp_patch.py`:

    kubectl -n <ns> cp patches/mcp_patch.py <pod>:/opt/data/mcp_patch.py -c hermes-agent

---

## 2. Adding tenant-specific MCP servers (HA / n8n / Odoo)

MCP server URLs are per-tenant (each customer has their own private-token
endpoint), so they live in `/opt/data/config.yaml` under `mcp_servers:`
rather than the shared manifest. Example structure:

```yaml
mcp_servers:
  odoo-mcp:
    url: https://<odoo-mcp-host>/private_<token>/mcp
  home-assistant-mcp:
    url: https://<ha-mcp-host>/private_<token>
    # no /mcp or /sse suffix — server autonegotiates
  n8n-mcp:
    # IMPORTANT: use /mcp (HTTP JSON-RPC) — NOT /sse. The SSE endpoint
    # only accepts GET for streaming; POST /sse returns 404 and hermes'
    # `hermes mcp add` reports "Session terminated".
    url: https://<n8n-mcp-host>/private_<token>/mcp
  browserless-mcp:
    url: https://mcp.browserless.io/mcp
    headers:
      Authorization: Bearer ${MCP_BROWSERLESS_MCP_API_KEY}
  cloudflare-mcp:
    url: https://mcp.cloudflare.com/mcp
    auth: oauth
  higgsfield:
    url: https://mcp.higgsfield.ai/mcp
    auth: oauth
```

After editing, verify with:

    kubectl exec <pod> -c hermes-agent -- hermes mcp list
    kubectl exec <pod> -c hermes-agent -- hermes mcp test '<server-name>'

For `auth: oauth` servers, run `hermes mcp login <name>` inside the
pod — it prints a browser URL. Complete auth in your browser; the
redirect will fail to load (points to pod's localhost) but the URL in
the address bar (with `?code=...&state=...`) can be pasted back into
the still-waiting CLI.

Tip: because `nohup ... &` redirects stdin to `/dev/null`, use a
persistent stdin pipe pattern to keep the CLI waiting for your paste:

    kubectl exec <pod> -c hermes-agent -- bash -c '
      mkfifo /tmp/oauth_stdin
      hermes mcp login <name> < /tmp/oauth_stdin > /tmp/oauth.log 2>&1 &
      # ... browse to URL, get callback URL, then:
      echo "<callback-url>" > /tmp/oauth_stdin
    '
