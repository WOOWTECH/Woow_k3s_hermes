#!/bin/bash
# T2 full video pipeline for dashboard TUI test
set -e
export PLAYWRIGHT_BROWSERS_PATH=/opt/data/playwright-browsers

WORK=/tmp/wt2
rm -rf "$WORK" && mkdir -p "$WORK"/{clip,narr,seg}
cd "$WORK"

# ── 1) HTML with 2 slides ──
cat > s.html <<'HTML'
<!doctype html><meta charset=utf-8><style>
body{margin:0;background:#0d1b2a;color:#fff;font-family:sans-serif;
display:flex;align-items:center;justify-content:center;height:100vh}
h1{font-size:4rem;margin:0}
p{font-size:1.5rem;opacity:.8}
section{text-align:center}
</style>
<section id="s1"><h1>WoowTech</h1><p>Video pipeline demo · Slide 1</p></section>
<section id="s2" style="display:none"><h1>End-to-End OK</h1><p>Slide 2 完成</p></section>
HTML
echo "[1/5] html $(stat -c %s s.html) bytes"

# ── 2) TTS ──
edge-tts --text "WoowTech video pipeline demo, slide one" --voice en-US-AriaNeural --write-media narr/n1.mp3
edge-tts --text "End to end pipeline works, slide two done" --voice en-US-GuyNeural --write-media narr/n2.mp3
echo "[2/5] mp3: n1=$(stat -c %s narr/n1.mp3), n2=$(stat -c %s narr/n2.mp3)"

# ── 3) Playwright capture per slide ──
/opt/hermes/.venv/bin/python3 <<'PY'
import asyncio, os
from playwright.async_api import async_playwright
async def cap(idx):
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        c = await b.new_context(
            viewport={'width':960,'height':540},
            record_video_dir='/tmp/wt2/clip',
            record_video_size={'width':960,'height':540})
        pg = await c.new_page()
        await pg.goto('file:///tmp/wt2/s.html')
        await pg.evaluate(f"document.querySelectorAll('section').forEach((s,i)=>s.style.display=i==={idx}?'block':'none')")
        await pg.wait_for_timeout(2500)
        await c.close(); await b.close()
asyncio.run(cap(0))
asyncio.run(cap(1))
# Rename to c1/c2
import glob
files = sorted(glob.glob('/tmp/wt2/clip/*.webm'), key=lambda f: os.path.getmtime(f))
for i, f in enumerate(files, 1):
    os.rename(f, f'/tmp/wt2/clip/c{i}.webm')
print(f'[3/5] webm captured: ' + ', '.join(f'c{i}=' + str(os.path.getsize(f"/tmp/wt2/clip/c{i}.webm")) for i in (1,2)))
PY

# ── 4) Build segments (audio-align) ──
for i in 1 2; do
  D=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 narr/n$i.mp3)
  ffmpeg -y -loglevel error -stream_loop -1 -i clip/c$i.webm -i narr/n$i.mp3 \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest -t "$D" \
    seg/s$i.mp4 2>&1 | tail -2
done
echo "[4/5] seg: s1=$(stat -c %s seg/s1.mp4), s2=$(stat -c %s seg/s2.mp4)"

# ── 5) Concat + verify ──
printf "file 'seg/s1.mp4'\nfile 'seg/s2.mp4'\n" > cat.txt
ffmpeg -y -loglevel error -f concat -safe 0 -i cat.txt -c copy final.mp4
echo "[5/5] final.mp4 = $(stat -c %s final.mp4) bytes"
ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,codec_type,width,height -of default=noprint_wrappers=1 final.mp4
echo "===== DONE ====="
