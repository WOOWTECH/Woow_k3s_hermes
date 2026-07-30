# WebUI removal (2026-07-30)

The `hermes-webui` sidecar container was removed from the deployment in
CHANGELOG [0.17.0]. This document explains what changed and how to migrate.

## What was removed

- Container: `ghcr.io/nesquena/hermes-webui:latest`
- Service: `hermes-webui-svc` (port 8787)
- Public URL: the port-8787 route (previously served the WebUI chat page)
- ConfigMap: `webui-oauth-patch`
- Secret key: any `WEBUI_PASSWORD` intended for WebUI login (the same
  key name is retained if you're also running the ttyd terminal, per
  `11-terminal.yaml`)
- Repo files: `patches/webui-oauth-callback-proxy.py` (if present),
  `instances/` (per-tenant overrides), `branding/` (WebUI branding
  patches — `apply_branding_*.py` targeted `/app/static/index.html`
  and `/app/api/routes.py` in the now-removed image)

## What replaces it

**Dashboard TUI** at `https://<dashboard-host>/chat` — an xterm.js
REPL of `hermes chat` running inside the hermes-agent container. Full
access to ffmpeg, edge-tts, rclone, playwright, node, and all 61
hermes CLI subcommands (WebUI could only see python3+pip+curl+officecli).

Chat sessions from the old WebUI are still on the PVC (data preserved)
but are not read by the Dashboard — treat them as archive.

## Why

- WebUI's gateway backend hit an upstream `dict.model_dump()`
  AttributeError on MiniMax tool_use responses (see historical
  troubleshooting §2 in git history before this release).
- WebUI's own container image ships almost no CLI tools, so any real
  workflow (video pipeline, rclone upload, ffmpeg processing) failed
  with `command not found` (see historical §3 and §5).
- Dashboard TUI does everything WebUI did and more.
- Removing WebUI saves ~200 MB memory + one container + one Service
  + one ConfigMap + one Secret key + one Cloudflare tunnel route.

## Secret migration: WEBUI_PASSWORD → TTYD_PASSWORD

The `WEBUI_PASSWORD` key in `hermes-secrets` was previously reused by the
ttyd browser terminal (see `11-terminal.yaml`). Removing WEBUI_PASSWORD
outright would break ttyd login.

For clusters upgrading through this release, run:

```bash
NS=<your-namespace>
# 1. Extract the current WEBUI_PASSWORD value
PWD=$(kubectl -n $NS get secret hermes-secrets -o jsonpath='{.data.WEBUI_PASSWORD}' | base64 -d)

# 2. Add it as TTYD_PASSWORD (same value — no need to rotate at migration time)
kubectl -n $NS patch secret hermes-secrets --type=json \
  -p="[{\"op\":\"add\",\"path\":\"/data/TTYD_PASSWORD\",\"value\":\"$(printf '%s' \"$PWD\" | base64 -w0)\"}]"

# 3. Re-apply the terminal manifest so ttyd picks up TTYD_PASSWORD via secretKeyRef
kubectl -n $NS apply -f deploy/k3s/manifests/11-terminal.yaml

# 4. Wait for ttyd rollout, verify browser login still works, then remove the old key
kubectl -n $NS rollout status deploy/hermes-terminal --timeout=120s
kubectl -n $NS patch secret hermes-secrets --type=json \
  -p='[{"op":"remove","path":"/data/WEBUI_PASSWORD"}]'
```

If your deploy script (`deploy-instance.sh`) sets the secret at initial
deploy time, ensure it sets `TTYD_PASSWORD` on fresh installs.

## Rollback

The commits that removed WebUI form a coherent series on branch
`remove-webui-sidecar` (or however it was merged into k3s):

    git log --oneline | grep -E "remove hermes-webui|de-tenant|CHANGELOG.*0\.17\.0"

To roll back, revert those commits and re-apply the manifests:

    git revert <commits>
    kubectl -n <ns> apply -f deploy/k3s/manifests/06-hermes.yaml
    kubectl -n <ns> apply -f deploy/k3s/manifests/09-ingress.yaml
    kubectl -n <ns> apply -f deploy/k3s/manifests/10-network-policy.yaml

PVC data was not touched, so all previous WebUI state (sessions,
`hermeswebui_init.bash` state, branding icons on the PVC) survives.
You'll also need to restore:
- The `webui-oauth-patch` ConfigMap (from git history)
- The Cloudflare tunnel route for the WebUI hostname (via CF dashboard)
- Any tenant `instances/<name>/` files you needed
