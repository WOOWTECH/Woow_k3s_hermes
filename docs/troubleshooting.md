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

---

## 5. Which chat surface can invoke ffmpeg / edge-tts / rclone / playwright?

**TL;DR** — the **Dashboard TUI on port 9119** (`https://<dashboard-host>/chat`),
NOT the WebUI on port 8787. They run in **different containers** and expose
different tool sets.

### Container-vs-tool matrix (verified 2026-07-30 on woow-k3s live cluster)

| Tool | hermes-agent container | hermes-webui container |
|------|------------------------|------------------------|
| `hermes` CLI + 61 subcommands | ✓ /usr/local/bin | ✗ |
| `ffmpeg` / `ffprobe` / `ffplay` 7.1.5 | ✓ /usr/bin | ✗ |
| `edge-tts` CLI + `edge_tts` python module | ✓ (installer wires both) | ✗ |
| `rclone` v1.74.4 | ✓ /opt/data/bin | ✗ |
| `node` v22 + `npm` | ✓ | ✗ |
| `playwright` python + Chromium 149 | ✓ (installer) | ✗ |
| `officecli` 1.0.135 | ✓ | ✓ (via /shared-tools sidecar + `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true` + `/usr/local/bin` symlink) |
| `python3` | 3.13.5 (hermes venv) | 3.12.13 + pip |
| `curl` | ✓ | ✓ |

Everything else is agent-only.

### Which chat runs in which container?

| Chat surface | Runs in | Composer type | Can invoke video pipeline? |
|--------------|---------|---------------|-----|
| **WebUI chat** (port 8787, `https://<host>/chat`) | **hermes-webui** container | Native HTML form + streaming | ❌ **NO** — webui container has none of ffmpeg/edge-tts/rclone/playwright |
| **Dashboard TUI** (port 9119, `https://<dashboard-host>/chat`) | **hermes-agent** container (xterm.js REPL of `hermes chat`) | xterm.js live terminal | ✅ **YES** — full agent-container tool access (13 native tools + 144 skills + 6 MCP servers) |

The WebUI terminal tool spawns from webui-container's shell, not proxied to
the agent. Same limitation applies to WebUI's file/write tool paths — they
resolve inside webui-container's filesystem, which mostly overlaps with the
PVC via `/home/hermeswebui/.hermes` but does NOT see agent-only paths like
`/opt/hermes/.venv/` or `/usr/bin/ffmpeg`.

**Practical guidance**

- Interactive Q&A, MCP tool calls (Odoo/HA/browserless/etc.), skill lookups
  → WebUI chat is fine and preferred (nicer UI, mobile-friendly).
- Video pipeline, batch shell jobs, anything needing ffmpeg/edge-tts/rclone,
  Playwright captures, or any local CLI beyond `python3+curl+officecli`
  → Dashboard TUI or a `hermes cron` job.
- Neither surface should be the primary automation entry point for
  production — use `hermes cron` (already runs in agent container) for
  scheduled batches.

### Verified evidence — Dashboard TUI orchestrating video pipeline

Two end-to-end tests run from Dashboard TUI (`Chat` tab on port-9119 dashboard):

| Test | Prompt | Agent tool calls | Output |
|------|--------|------------------|--------|
| **T1 micro** | Inline 4-step: `mkdir` + `edge-tts` + `ffmpeg` + `ffprobe` | Terminal ×5 (0.0-2.0s each) | 640×360 3.19s h264+aac 29859-byte MP4 |
| **T2 full** | `bash /opt/data/t2_full_pipeline.sh` (2-slide HTML → 2 TTS → 2 Playwright captures → 2 segments → concat) | Terminal ×1 (12.4s wall time) | 960×540 7.099s h264+aac 426349-byte MP4 |

T2 was completed in a **single agent turn** (~1 minute total), consuming
~20k of 196k context window (10%). Same script under `tests/video-tui-t2-pipeline.sh`.

### WebUI chat quick smoke

If you MUST test something video-pipeline-shaped from WebUI, keep it to what
webui-container actually has:

    Use terminal to run: python3 -c "import base64; print('py-ok')"
    Use terminal to run: curl -sI https://example.com | head -1
    Use terminal to run: officecli --version

These all pass. Anything referring to `ffmpeg`, `edge-tts`, `rclone`,
`playwright`, `node`, `hermes` will return `command not found` (exit 127).
