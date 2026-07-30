# Changelog

All notable changes to the WoowTech Hermes Agent deployment package.

## [0.16.1] - 2026-07-29

### Fixed
- **WebUI chat blocked by upstream `dict.model_dump()` AttributeError** when
  MiniMax (any variant) or other providers stream `type: "thinking"` content
  with tool_use loaded. Root cause: `HERMES_WEBUI_CHAT_BACKEND=gateway`
  routes through a hermes-gateway serialization path that assumes pydantic
  models. Template `06-hermes.yaml` now leaves this env unset (falls back to
  WebUI's default in-process runtime, per upstream WebUI docs). CLI
  invocations (`hermes -z ...`) were unaffected all along — only the
  gateway-backed WebUI path triggered it.
- **`officecli: command not found` inside hermes-webui container.** Two
  compounding bugs: (a) webui login-shell profile strips `/opt/shared-tools`
  from PATH, so the shared officecli was invisible to `bash -lc`
  invocations; (b) webui image lacks libicu, causing officecli (a .NET
  binary) to abort on startup. Template now (i) copies officecli from PVC
  into `/shared-tools` in the agent postStart, (ii) symlinks
  `/opt/shared-tools/officecli -> /usr/local/bin/officecli` in the webui
  startup script (always in PATH regardless of shell mode), and (iii) sets
  `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true` on the webui container to
  bypass the ICU requirement.

### Added
- `docs/troubleshooting.md` — field notes on the four biggest deployment
  gotchas: blank dashboard, WebUI chat AttributeError, officecli PATH,
  and per-tenant MCP server config (HA / n8n endpoints, OAuth login flow
  with the persistent-stdin fifo trick).
- Agent postStart now auto-runs `/opt/data/mcp_patch.py` (from [0.16.0]) if
  present — no manual re-run needed after pod restarts. Copy the script to
  the PVC once with `kubectl cp` and future pods self-patch.

### Notes
- HA MCP endpoint pattern: `https://<host>/private_<token>` — no `/mcp` or
  `/sse` suffix (server autonegotiates protocol on the base URL).
- n8n-mcp endpoint pattern: `https://<host>/private_<token>/mcp` (HTTP
  JSON-RPC). Do NOT use `/sse` — that endpoint only accepts GET for
  streaming, and `hermes mcp add` will report `Session terminated`.

## [0.16.0] - 2026-07-29

### Fixed
- **Dashboard blank-page bug from OAuth patch**: previous `patches/mcp-oauth-all-http.sh`
  was triply-broken and caused the whole dashboard SPA to render an empty root div.
  Rewrote the script to:
  1. Target `McpPage-*.js` (the code-split chunk containing the Authenticate button)
     instead of `index-*.js` (where the code no longer lives after upstream Vite refactor).
  2. Use a name-agnostic regex `(0,[a-z]\.jsx)([a-z]` instead of hard-coded `(0,W.jsx)(G,`
     — upstream minifier now emits `b`/`g`.
  3. **Not** rename the chunk file. The previous behavior copied the bundle to
     `index-OAuthFix{timestamp}.js` and rewrote `index.html` to match, which broke
     Vite's code-splitting singletons (e.g. `usePageHeader-*.js` imports from the
     ORIGINAL filename hard-coded at build time) → dual React context instances →
     `usePageHeader must be used within a PageHeaderProvider` crash → blank dashboard.

### Added
- `patches/mcp_patch.py` — idempotent Python patch invoked by the shell wrapper (or
  from the agent postStart hook if you copy it to the PVC at `/opt/data/mcp_patch.py`).
- `deploy/k3s/manifests/12-disk-cleanup-cronjob.yaml` — nightly (03:00 UTC) prune of
  `request_dump_*.json > 7d`, `_run_journal > 30d`, `curator/*` logs, and rotated
  gateway logs (keep newest 3). Uses `podAffinity` to satisfy Longhorn's RWO
  single-node attach constraint. Recommended alongside expanding the PVC 5→20Gi
  via `kubectl patch pvc hermes-webui-data -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'`.

### Notes for existing deployments
- Browser HTTP cache on `/assets/*.js` is `max-age=14400` (4h). After running the
  fixed OAuth patch, users must hard-refresh (Ctrl+Shift+R) to see the change.
- MiniMax-M2.7-highspeed triggers a hermes-agent `dict.model_dump()` AttributeError
  when tool_use is involved (WebUI + skills/MCP, or cron jobs with tools). Workaround:
  set `model.default: MiniMax-M2` in `/opt/data/config.yaml` — proven stable multi-turn
  with tool_use. The bug lives in `chat_completion_helpers.py` lines 1490/1580/3250
  and `transports/chat_completions.py:688` (calls `.model_dump()` assuming pydantic
  model, receives dict). Reproducible under M2.7-highspeed's thinking-mode responses.

## [0.15.1] - 2026-07-13

### Changed
- Restructured GitHub repo: clean layout with `deploy/`, `config/`, `docker/`, `branding/`, `tests/`
- Added bilingual README (English + Traditional Chinese) with Mermaid architecture diagrams
- Removed OpenClaw content pollution from k3s/podman branches

## [0.15.0] - 2026-07-12

### Fixed
- Model routing: added `@openai-api:*` routes for WebUI model picker compatibility
- Synced model list with WebUI picker (added gpt-5.5-pro, gpt-5.4-nano, removed gpt-5.5-mini)

### Added
- `.env` fingerprint sync patch for K3s/Podman deployments
- Playwright-based E2E test suite (10/10 pass)

## [0.14.0] - 2026-06

### Added
- Multi-instance deployment with `deploy-instance.sh`
- White-label branding system (WoowTech + Apporo templates)
- Golden config/settings templates (`golden-config.yaml`, `golden-settings.json`)
- Cloudflare Tunnel initialization script
- Instance registry (`instances.json`)

## [0.13.0] - 2026-05

### Added
- Custom Docker image with 47 CLI tools + Playwright + Chromium 148
- 7-round enterprise test suite (infrastructure, API, security, resilience, integration, LLM, WebUI)
- API contract documentation (46 verified endpoints)
- Podman compose deployment option
- 907-line Chinese user manual (25 chapters)

## [0.12.0] - 2026-04

### Added
- Initial Hermes Agent deployment on K3s Kubernetes
- Basic deploy.sh for single-instance deployment
- PostgreSQL + Redis stack
