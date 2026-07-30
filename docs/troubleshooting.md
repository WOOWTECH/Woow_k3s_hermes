# Troubleshooting

Field-notes for known upstream/bundling issues encountered on live deployments.
Fixes here are already wired into `deploy/k3s/manifests/06-hermes.yaml` — this
document exists so operators understand *why* the workarounds are there and
what breaks if they're removed.

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

## 2. WebUI chat fails with `'dict' object has no attribute 'model_dump'`

**Symptom**
Sending a message in the WebUI triggers 3 retries, then the fallback model
is tried and eventually returns an error. hermes-agent log shows
`AttributeError` inside `agent.conversation_loop` when the provider is
MiniMax (any variant, including MiniMax-M2 / MiniMax-M2.7-highspeed) OR
another provider that streams `type: "thinking"` content chunks.

CLI invocations (`hermes -z ...`) do NOT reproduce it, even with the same
model. Only the WebUI-through-gateway path triggers.

**Root cause**
`HERMES_WEBUI_CHAT_BACKEND=gateway` routes browser turns through the
hermes gateway's chat-completions bridge. Somewhere in that bridge's
serialization path an unguarded `.model_dump()` is called on a payload
that MiniMax returns as a plain dict (thinking-mode content isn't a
recognized pydantic schema in the current hermes gateway build).

**Fix**
Unset the env var (or leave it out of the deployment) so WebUI uses its
default **in-process legacy runtime**. Confirmed by upstream WebUI docs
(`/app/docs/advanced-chat-setup.md`):

> By default, browser chat runs through WebUI's in-process legacy runtime.
> Most users need neither [gateway nor api_server backends] — the defaults
> (in-process chat, no prefill) work out of the box.

The template `06-hermes.yaml` leaves the env commented out.

---

## 3. `officecli: command not found` inside the hermes-webui container

**Symptom**
Agent's terminal tool inside WebUI reports exit 127 for
`officecli --version`, even though `/opt/data/officecli` exists on the PVC.

**Root causes (both had to be fixed)**

1. **PATH strip in login shells.** The hermes-webui container's
   `bash -l` login shell loads a profile that resets PATH to
   `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, stripping
   `/opt/shared-tools` (where the shared officecli lives). Non-login shells
   keep the full PATH, but many tool invocations (including hermes' terminal
   tool) go through login shells.
2. **Missing ICU package.** officecli is a .NET binary. The webui image
   doesn't ship libicu, so officecli aborts at startup with
   `Couldn't find a valid ICU package installed on the system`.

**Fixes (both in template)**

- Agent postStart copies officecli into the shared tools volume:
  `cp /opt/data/officecli /shared-tools/officecli`
- WebUI startup script symlinks it into `/usr/local/bin` (always in PATH
  regardless of login mode): `ln -sf /opt/shared-tools/officecli /usr/local/bin/officecli`
- WebUI env sets `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true` to bypass
  the ICU requirement.

Verification (all three shell modes should return the version):

    kubectl exec <pod> -c hermes-webui -- sh -c   'which officecli && officecli --version'
    kubectl exec <pod> -c hermes-webui -- bash -c 'which officecli && officecli --version'
    kubectl exec <pod> -c hermes-webui -- bash -lc 'which officecli && officecli --version'

---

## 4. Adding tenant-specific MCP servers (HA / n8n / Odoo)

MCP server URLs are per-tenant (each customer has their own private-token
endpoint), so they live in `/opt/data/config.yaml` under `mcp_servers:`
rather than the shared manifest. Example structure:

```yaml
mcp_servers:
  woowtech-odoo-mcp:
    url: https://woowtech-mcp-odoo.woowtech.io/private_<token>/mcp
  home-assistant-mcp:
    url: https://woowtech-mcp.woowtech.io/private_<token>
    # no /mcp or /sse suffix — server autonegotiates
  n8n-mcp:
    # IMPORTANT: use /mcp (HTTP JSON-RPC) — NOT /sse. The SSE endpoint
    # only accepts GET for streaming; POST /sse returns 404 and hermes'
    # `hermes mcp add` reports "Session terminated".
    url: https://n8n-mcp.woowtech.io/private_<token>/mcp
  browserless-mcp:
    url: https://mcp.browserless.io/mcp
    headers:
      Authorization: Bearer ${MCP_BROWSERLESS_MCP_API_KEY}
  cloudflare-mco:
    url: https://mcp.cloudflare.com/mcp
    auth: oauth
  Higgsfield:
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
