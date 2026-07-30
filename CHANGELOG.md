# Changelog

All notable changes to the WoowTech Hermes Agent deployment package.

## [0.17.0] - 2026-07-30 — BREAKING: single-container architecture

### Removed
- **`hermes-webui` sidecar container** (`ghcr.io/nesquena/hermes-webui:latest`, port 8787) and everything wired to it:
  - `hermes-webui-svc` Service
  - `webui-oauth-patch` ConfigMap content and mount
  - `/` ingress path (kept `/api` → agent gateway)
  - NetworkPolicy `hermes-webui` podSelectors from postgres/redis rules
  - CF tunnel route for the `hermes-` (webui) hostname is deleted separately from Cloudflare dashboard — see [docs/migration/2026-07-30-webui-removal.md](docs/migration/2026-07-30-webui-removal.md)

### Removed (de-tenant)
- `instances/` directory (per-tenant overrides for prior tenants preserved in git history)
- `instances/instances.json`
- `deploy/k3s/deploy-apporo-team.sh` (tenant-specific)
- `branding/` (both `apporo/` and `woowtech/`) — the `apply_branding_*.py`
  scripts patched WebUI internals (`/app/static/index.html`,
  `/app/api/routes.py`) which are gone with the WebUI image
- `deploy/k3s/init-cloudflare-hermes.py` (WebUI-tunnel-only; replaced by dashboard-focused route creation in `deploy.sh`)
- `config/deploy-and-test.sh`, `config/post-deploy-setup.sh` (2-container assumptions)
- `tests/round6-llm-integration.sh`, `tests/round7-webui-features.sh`,
  `tests/test-instance.sh`, `tests/run-dual-instance-e2e.sh`,
  `tests/playwright/hermes-webui.spec.mjs`,
  `tests/playwright/hermes-webui-features.spec.mjs`
  (WebUI feature suites + tenant-dependent E2E)
- `scripts/strip_webui.py` (one-shot migration helper)

Repo is now a generic template. Tenants own their overrides in their own
repos or branches.

### Changed
- `deploy/k3s/manifests/06-hermes.yaml` — one container (hermes-agent), one Service (hermes-agent-svc)
- `deploy/k3s/manifests/09-ingress.yaml` — `/` path removed; `/api` retained → `hermes-agent-svc:8642`
- `deploy/k3s/manifests/10-network-policy.yaml` — `hermes-webui` podSelectors removed
- `deploy/k3s/manifests/02-configmap.yaml` — `HERMES_WEBUI_PORT` key removed
- `deploy/k3s/deploy.sh` — dropped `07-hermes-webui.yaml` from apply loop; CF tunnel route created against dashboard (`hermes-agent-svc:9119`) instead of WebUI
- `deploy/k3s/deploy-instance.sh` — dropped WEBUI_IMAGE / port / password / state-dir vars, generic `<tenant>` placeholder
- `tests/round1-infra.sh`, `round2-api.sh`, `round4-resilience.sh`, `round5-integration.sh`, `tests/lib/assert.sh`, `tests/run-all.sh` — WebUI test paths removed; agent-only paths retained
- `README.md`, `README_zh-TW.md` — Dual-GUI claim retired; Dashboard TUI is now the sole chat surface; architecture/mermaid/tables/service-URLs updated accordingly
- `docs/troubleshooting.md` — pruned 226→95 lines; dropped obsolete WebUI-specific §2/§3/§5; kept §1 (dashboard blank page) and §2 (per-tenant MCP) with tenant names genericised
- `docs/user-manual-zh-TW.md` — tenant table + login URL genericised; chapter walkthroughs retained as historical reference with "example deployment" caveat
- `docs/api-contract.md`, `CONTRIBUTING.md` — dropped WebUI + branding references
- `deploy/k3s/manifests/11-terminal.yaml` — ttyd basic-auth now reads `TTYD_PASSWORD` instead of the shared `WEBUI_PASSWORD` key

### Added
- `docs/migration/2026-07-30-webui-removal.md` — operator migration guide: what was removed, what replaces it (Dashboard TUI at :9119), why, and how to roll back

### Preserved (not touched — for rollback)
- PVC `hermes-webui-data` (name retained; same PVC is mounted by hermes-agent at `/opt/data`, so all prior WebUI sessions/branding icons/OAuth tokens remain accessible)
- `WEBUI_PASSWORD` key in `hermes-secrets` **replaced** by `TTYD_PASSWORD` for ttyd browser terminal — see migration doc for kubectl commands
- Historical CHANGELOG entries (audit trail)
- Historical tenant + WebUI files in git history (accessible via `git log --all`)

### Migration
See [docs/migration/2026-07-30-webui-removal.md](docs/migration/2026-07-30-webui-removal.md).
The Dashboard TUI on port 9119 (`https://<dashboard-host>/chat` — xterm.js REPL of `hermes chat`) replaces the WebUI chat surface entirely. It runs inside the hermes-agent container which has ffmpeg, edge-tts, rclone, playwright, and all 61 hermes CLI subcommands — versus WebUI which could only invoke `python3+pip+curl+officecli`.

### Rationale
- WebUI's gateway backend hit an upstream `dict.model_dump()` AttributeError on MiniMax tool_use responses (documented in the git history of [0.16.1]).
- WebUI image doesn't ship the CLI tools most real workflows need (documented in the [0.16.4] container-vs-tool matrix).
- Single-container reduces memory by ~200 MB and eliminates the "which chat should I use?" question.
- Dashboard TUI end-to-end verified via T1/T2 pipeline tests ([0.16.4]).

## [0.16.4] - 2026-07-30

### Added
- `tests/video-tui-t2-pipeline.sh` — reference "single-agent-invoke" pipeline
  script. After `kubectl cp` into the pod's `/opt/data/`, an agent turn as
  short as `bash /opt/data/t2_full_pipeline.sh` produces a full 2-slide narrated
  MP4. Verified: 12.4s wall time, 960×540 7.099s h264+aac 426349-byte output,
  one agent Terminal tool call, ~20k of 196k context (10%).

### Documentation
- `docs/troubleshooting.md` gains a new §5 "Which chat surface can invoke
  ffmpeg / edge-tts / rclone / playwright?" documenting the critical
  Dashboard-TUI-vs-WebUI-chat container split. Contains a full container-vs-
  tool matrix and verified T1/T2 evidence from the woow-k3s live cluster.
  Practical guidance: video-pipeline / heavy-CLI work → Dashboard TUI or
  `hermes cron`, NOT WebUI chat.
- README.md + README_zh-TW.md `Video Pipeline E2E Tests` / `影片 Pipeline
  E2E 測試` subsections both gain a short paragraph pointing readers to the
  correct chat surface + the T2 fixture, cross-linked to troubleshooting §5.

### Rationale
- WebUI chat (port 8787, hermes-webui container) has almost no video tools
  installed — the image ships `python3+pip+curl+officecli` and not much
  else. Any prompt saying "run ffmpeg" or "run edge-tts" in WebUI returns
  exit 127. This was not obvious to operators; codifying it prevents the
  "why is chat useless for video?" support cycle.
- Dashboard TUI (port 9119, hermes-agent container) IS the video-capable
  chat — verified by orchestrating full pipeline in one agent turn.

## [0.16.3] - 2026-07-30

### Added
- `tests/video-e2e-happy.sh` — full happy-path E2E test for the slide-to-video
  pipeline. Generates a 3-slide HTML + narration script inline, then walks the
  entire pipeline: edge-tts → Playwright WebM capture → ffmpeg segment build
  (audio-aligned) → concat demuxer → srt+pysubs2 subtitle round-trip →
  ffmpeg subtitle burn → ffprobe quality gates (h264+aac codec, resolution,
  size, duration). Verified 6/6 stages Pass on live cluster; produces a
  539.5 KB / 15.38s / 1280×720 MP4 in ~60-90s.
- `tests/video-e2e-edges.sh` — 10-case adversarial edge battery:
    1. edge-tts empty text (lenient behavior)
    2. 60s+ TTS (memory/latency)
    3. Special chars (emoji + CJK + URL + quotes)
    4. Playwright micro-capture (0.3s)
    5. Playwright 1920×1080 scroll-through
    6. ffmpeg concat with mismatched resolutions (auto-scale filter)
    7. srt+pysubs2 tricky chars round-trip
    8. ffmpeg burn tricky SRT
    9. rclone CLI without config (fail-soft check)
    10. 2× concurrent Playwright contexts (isolation)

  Verified 10/10 Pass on live cluster. Both scripts exit non-zero on failure —
  safe for CI/pre-push gates.

### Documentation
- README.md + README_zh-TW.md `## Testing / ## 測試` sections now include a
  "Video Pipeline E2E Tests" subsection with kubectl-based run instructions,
  suite coverage table, and reference to CHANGELOG [0.16.2] for prerequisites.

## [0.16.2] - 2026-07-30

### Added
- `patches/install_video_pipeline.sh` — idempotent installer for the
  slide-to-video Pipeline (TTS → Playwright capture → ffmpeg concat/xfade →
  SRT burn → rclone upload). Auto-runs from hermes-agent postStart if
  present at `/opt/data/install_video_pipeline.sh`. Fast path (~1s) when
  everything is already installed; cold path (~2 min) downloads:
    * `rclone` v1.74.4 into `/opt/data/bin/` (extracted via python zipfile —
      base image doesn't ship `unzip`)
    * Playwright's full Chromium 149.x (`chrome-linux64/chrome`, not the
      pre-existing `chromium_headless_shell-1228` which lacks headed
      video-record support)
    * python packages into hermes venv via `uv`: `playwright`, `edge-tts`,
      `srt`, `pysubs2`
    * `edge-tts` CLI symlink → `/usr/local/bin/edge-tts` (module was already
      at `/opt/data/lazy-packages/bin/`, just not on PATH)

  Total footprint ~430 MB — all under `/opt/data`, PVC-persisted, survives
  pod restarts.

### Notes
- Base hermes-agent image has no `pip` binary in the venv (uses `uv` for
  package management). Installer detects this and uses
  `uv pip install --python /opt/hermes/.venv/bin/python3 ...` instead.
- Playwright 149.x renamed the Chromium binary path from `chrome-linux/`
  to `chrome-linux64/`. Installer probes with a glob for future-proofing.
- rclone Google Drive setup remains a one-time human step:
    kubectl -n <ns> exec -it <pod> -c hermes-agent -- /opt/data/bin/rclone config
  Then move `~/.config/rclone/rclone.conf` to `/opt/data/rclone.conf` so it
  survives pod restarts.

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
