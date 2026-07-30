#!/bin/bash
# Video Production Pipeline installer for hermes-agent pods.
#
# What this installs (all idempotent — safe to re-run):
#   1. rclone binary (Google Drive/S3/etc. upload)   → /opt/data/bin/rclone
#   2. python packages in hermes venv                → playwright, edge-tts, srt, pysubs2
#   3. Playwright's FULL Chromium (not just headless-shell) for `record_video_dir` support
#   4. edge-tts CLI symlink                          → /usr/local/bin/edge-tts
#
# Not installed here (needs one-time human action):
#   - `rclone config` for Google Drive OAuth. Run interactively once:
#         kubectl -n <ns> exec -it <pod> -c hermes-agent -- /opt/data/bin/rclone config
#     The resulting `~/.config/rclone/rclone.conf` should be moved to
#     `/opt/data/rclone.conf` so it survives pod restarts (PVC-backed).
#
# Storage impact (all under /opt/data, PVC-backed → persists across pod restarts):
#   - rclone:                    ~8 MB
#   - python packages:          ~40 MB
#   - Chromium (full):          ~380 MB
#   Total:                     ~430 MB
#
# Safe to call from postStart on every pod restart — every step no-ops if already
# present. Total run time on a warm PVC: <1s; on a cold pod: ~2 minutes.

set -eu

BIN_DIR="/opt/data/bin"
VENV="/opt/hermes/.venv"
PLAYWRIGHT_BROWSERS_PATH="/opt/data/playwright-browsers"
export PLAYWRIGHT_BROWSERS_PATH

mkdir -p "$BIN_DIR"

echo "[video-pipeline] === starting install (idempotent) ==="

# ────────────────────────────────────────────────────────────
# 1. rclone
# ────────────────────────────────────────────────────────────
if [ ! -x "$BIN_DIR/rclone" ]; then
  echo "[video-pipeline] downloading rclone..."
  TMP=$(mktemp -d)
  if curl -sfL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o "$TMP/r.zip"; then
    # No `unzip` in this base image — use python zipfile module (always present).
    python3 -c "
import zipfile, os, shutil
z = zipfile.ZipFile('$TMP/r.zip')
z.extractall('$TMP')
for root, _, files in os.walk('$TMP'):
    for f in files:
        if f == 'rclone':
            shutil.copy(os.path.join(root, f), '$BIN_DIR/rclone')
            break
"
    chmod +x "$BIN_DIR/rclone" 2>/dev/null
    rm -rf "$TMP"
    if [ -x "$BIN_DIR/rclone" ]; then
      echo "[video-pipeline] rclone: $($BIN_DIR/rclone version 2>&1 | head -1)"
    else
      echo "[video-pipeline] WARN: rclone extract failed"
    fi
  else
    echo "[video-pipeline] WARN: rclone download failed"
    rm -rf "$TMP"
  fi
else
  echo "[video-pipeline] rclone already present: $($BIN_DIR/rclone version 2>&1 | head -1)"
fi
ln -sf "$BIN_DIR/rclone" /usr/local/bin/rclone 2>/dev/null || true

# ────────────────────────────────────────────────────────────
# 2. Python packages (into hermes venv, works for both agent + cron)
# ────────────────────────────────────────────────────────────
# hermes venv uses uv, not pip — /usr/local/bin/uv is present in the image.
UV=$(command -v uv 2>/dev/null || echo "")
if [ -n "$UV" ] && [ -x "$VENV/bin/python3" ]; then
  MISSING=""
  for pkg_import in playwright:playwright edge_tts:edge-tts srt:srt pysubs2:pysubs2; do
    mod="${pkg_import%%:*}"
    pip_name="${pkg_import##*:}"
    if ! "$VENV/bin/python3" -c "import $mod" >/dev/null 2>&1; then
      MISSING="$MISSING $pip_name"
    else
      ver="$("$VENV/bin/python3" -c "import $mod; print(getattr($mod, '__version__', 'installed'))" 2>&1 | head -1)"
      echo "[video-pipeline] $pip_name already present: $ver"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "[video-pipeline] installing:$MISSING (via uv into hermes venv)..."
    VIRTUAL_ENV="$VENV" "$UV" pip install --python "$VENV/bin/python3" $MISSING 2>&1 | tail -3 || \
      echo "[video-pipeline] WARN: uv pip install failed"
  fi
else
  echo "[video-pipeline] WARN: uv or venv python3 missing — python deps skipped"
fi

# ────────────────────────────────────────────────────────────
# 3. Playwright's full Chromium (headed) — required for record_video_dir
#    The pod already has chromium_headless_shell-1228, but not the full
#    chromium-1228/chrome-linux/ tree that playwright's chromium channel expects.
# ────────────────────────────────────────────────────────────
# Playwright's Chromium binary name changed with 149.x: chrome-linux → chrome-linux64
CHROME_BIN=$(ls "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux*/chrome 2>/dev/null | head -1)
if [ -z "$CHROME_BIN" ] && [ -x "$VENV/bin/playwright" ]; then
  echo "[video-pipeline] installing playwright chromium (~380 MB, ~2 min)..."
  "$VENV/bin/playwright" install chromium 2>&1 | tail -3 || {
    echo "[video-pipeline] WARN: playwright install failed"; }
  CHROME_BIN=$(ls "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux*/chrome 2>/dev/null | head -1)
fi
if [ -n "$CHROME_BIN" ] && [ -x "$CHROME_BIN" ]; then
  echo "[video-pipeline] playwright chromium: $("$CHROME_BIN" --version 2>&1 | head -1) at $CHROME_BIN"
else
  echo "[video-pipeline] WARN: chromium binary not found after install"
fi

# ────────────────────────────────────────────────────────────
# 4. edge-tts CLI symlink (module is at /opt/data/lazy-packages/bin/edge-tts)
# ────────────────────────────────────────────────────────────
if [ -x /opt/data/lazy-packages/bin/edge-tts ] && [ ! -e /usr/local/bin/edge-tts ]; then
  ln -sf /opt/data/lazy-packages/bin/edge-tts /usr/local/bin/edge-tts
  echo "[video-pipeline] edge-tts CLI linked into /usr/local/bin"
fi

# ────────────────────────────────────────────────────────────
# 5. Report final state
# ────────────────────────────────────────────────────────────
echo "[video-pipeline] === final state ==="
for T in ffmpeg ffprobe rclone edge-tts; do
  V=$(command -v "$T" >/dev/null 2>&1 && "$T" --version 2>&1 | head -1 || echo "MISSING")
  printf "  %-10s %s\n" "$T" "$V"
done
for M in playwright edge_tts srt pysubs2 yaml; do
  V=$("$VENV/bin/python3" -c "import $M; print(getattr($M, '__version__', 'OK'))" 2>&1 | head -1)
  printf "  py:%-8s %s\n" "$M" "$V"
done
if [ -f /opt/data/rclone.conf ]; then
  echo "  rclone.conf: present ($(wc -l < /opt/data/rclone.conf) lines)"
else
  echo "  rclone.conf: MISSING — run 'rclone config' once and mv to /opt/data/rclone.conf"
fi
echo "[video-pipeline] === done ==="
