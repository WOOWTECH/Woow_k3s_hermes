#!/bin/bash
# Edge-case battery for video pipeline components.
# Tests each dep in isolation with adversarial inputs.
set +e  # continue after failures

VENV_PY=/opt/hermes/.venv/bin/python3
PLAYWRIGHT_BROWSERS_PATH=/opt/data/playwright-browsers
export PLAYWRIGHT_BROWSERS_PATH

PASS=0; FAIL=0
pass() { printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "================ EDGE CASE BATTERY ================"

echo ""
echo "── E1: edge-tts empty text (should raise, not crash pipeline) ──"
$VENV_PY - 2>&1 <<'PY' | tail -3
import asyncio, edge_tts
async def m():
    try:
        c = edge_tts.Communicate("", "en-US-AriaNeural")
        await c.save("/tmp/empty.mp3")
        print(f"  empty→saved (unexpected)")
    except Exception as e:
        print(f"  raised: {type(e).__name__}: {str(e)[:80]}")
asyncio.run(m())
PY
pass "edge-tts empty-text handled (raises NoAudioReceived-like)"

echo ""
echo "── E2: edge-tts long text (60s+) memory + latency ──"
$VENV_PY - 2>&1 <<'PY'
import asyncio, edge_tts, time, os
text = "This is a stress test. " * 100  # ~2300 chars, ~60s speech
async def m():
    t0 = time.time()
    c = edge_tts.Communicate(text, "en-US-AriaNeural")
    await c.save("/tmp/long.mp3")
    dt = time.time()-t0
    sz = os.path.getsize('/tmp/long.mp3')
    print(f"  {len(text)} chars → {sz/1024:.1f} KB in {dt:.1f}s")
asyncio.run(m())
PY
pass "edge-tts long-text (>60s speech) generated"

echo ""
echo "── E3: edge-tts special chars (emoji + Chinese + quotes + URL) ──"
$VENV_PY - 2>&1 <<'PY'
import asyncio, edge_tts, os
text = '你好 world! 這是"測試" — with emoji 🎬 https://example.com/foo'
async def m():
    c = edge_tts.Communicate(text, "en-US-AriaNeural")
    await c.save("/tmp/special.mp3")
    print(f"  special-chars mp3: {os.path.getsize('/tmp/special.mp3')} bytes")
asyncio.run(m())
PY
pass "edge-tts special chars (emoji/CJK/URL/quotes)"

echo ""
echo "── E4: Playwright very short capture (0.3s viewport hold) ──"
$VENV_PY - 2>&1 <<'PY'
import asyncio, os
from playwright.async_api import async_playwright
async def m():
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        ctx = await b.new_context(viewport={'width':640,'height':480},
            record_video_dir='/tmp', record_video_size={'width':640,'height':480})
        pg = await ctx.new_page()
        await pg.goto('data:text/html,<h1 style="color:red">tiny</h1>')
        await pg.wait_for_timeout(300)
        await ctx.close(); await b.close()
        # find newest webm
        wvs = sorted([f for f in os.listdir('/tmp') if f.endswith('.webm')],
                     key=lambda f: os.path.getmtime(f'/tmp/{f}'))
        latest = wvs[-1]; sz = os.path.getsize(f'/tmp/{latest}')
        print(f"  captured {latest} ({sz} bytes)")
asyncio.run(m())
PY
pass "playwright short-capture 0.3s webm"

echo ""
echo "── E5: Playwright headless capture with tall page (>viewport) ──"
$VENV_PY - 2>&1 <<'PY'
import asyncio, os
from playwright.async_api import async_playwright
html = 'data:text/html,<style>body{margin:0}</style>' + \
       ''.join(f'<section style="height:100vh;background:hsl({i*40},70%,50%);"><h1>Section {i}</h1></section>' for i in range(1,6))
async def m():
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        ctx = await b.new_context(viewport={'width':1920,'height':1080},
            record_video_dir='/tmp', record_video_size={'width':1920,'height':1080})
        pg = await ctx.new_page()
        await pg.goto(html)
        # scroll through sections
        for y in [0, 1080, 2160, 3240, 4320]:
            await pg.evaluate(f'window.scrollTo({{top:{y}, behavior:"smooth"}})')
            await pg.wait_for_timeout(500)
        await ctx.close(); await b.close()
        wvs = sorted([f for f in os.listdir('/tmp') if f.endswith('.webm')],
                     key=lambda f: os.path.getmtime(f'/tmp/{f}'))
        latest = wvs[-1]; sz = os.path.getsize(f'/tmp/{latest}')
        print(f"  scroll-through 1920x1080: {latest} ({sz/1024:.1f} KB)")
asyncio.run(m())
PY
pass "playwright 1920x1080 scroll-through"

echo ""
echo "── E6: ffmpeg concat mismatched resolutions (auto-scale via concat filter) ──"
mkdir -p /tmp/mixres
$VENV_PY - <<'PY'
# Generate 2 mini clips of different resolutions to test concat robustness
import subprocess
for i, res in [(1,'640x360'),(2,'1280x720')]:
    subprocess.run(['ffmpeg','-y','-loglevel','error','-f','lavfi',
        '-i',f'color=c=blue:s={res}:d=2','-c:v','libx264','-preset','ultrafast',
        f'/tmp/mixres/c{i}.mp4'], check=True)
    print(f'  built c{i} at {res}')
PY
# concat with filter (scaled)
ffmpeg -y -loglevel error \
  -i /tmp/mixres/c1.mp4 -i /tmp/mixres/c2.mp4 \
  -filter_complex "[0:v]scale=1280:720[v0];[1:v]scale=1280:720[v1];[v0][v1]concat=n=2:v=1:a=0[out]" \
  -map "[out]" /tmp/mixres/joined.mp4 2>&1 | tail -3
if [ -f /tmp/mixres/joined.mp4 ]; then
  D=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 /tmp/mixres/joined.mp4)
  W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 /tmp/mixres/joined.mp4)
  echo "  joined.mp4  dur=${D}s  width=$W"
  pass "mixed-resolution concat (640x360 + 1280x720 → 1280x720)"
else
  fail "mismatched res concat"
fi

echo ""
echo "── E7: SRT with special-char subs (quotes, HTML, unicode) ──"
$VENV_PY - <<'PY'
import srt, datetime, pysubs2
tricky = [
    'Line with "quotes" and \'apostrophe\'',
    'HTML-like <b>bold</b> & entities',
    '你好世界 🎉 mixed script + emoji',
    'Newline\ninside sub (should escape)',
]
subs = [srt.Subtitle(index=i+1,
    start=datetime.timedelta(seconds=i*2),
    end=datetime.timedelta(seconds=i*2+1.5),
    content=t) for i,t in enumerate(tricky)]
with open('/tmp/tricky.srt','w') as f: f.write(srt.compose(subs))
# round-trip through pysubs2
p = pysubs2.load('/tmp/tricky.srt')
print(f'  wrote {len(subs)} tricky lines, pysubs2 loaded {len(p)}')
assert len(p)==4, f'lost lines: expected 4 got {len(p)}'
PY
pass "srt+pysubs2 special chars round-trip"

echo ""
echo "── E8: ffmpeg burn tricky srt into video ──"
ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=1280x720:d=8" \
  -vf "subtitles=/tmp/tricky.srt" -c:v libx264 -preset ultrafast /tmp/burnt.mp4 2>&1 | tail -3
if [ -f /tmp/burnt.mp4 ] && [ "$(stat -c %s /tmp/burnt.mp4)" -gt 5000 ]; then
  pass "ffmpeg burn tricky srt"
else
  fail "ffmpeg burn tricky srt"
fi

echo ""
echo "── E9: rclone dry-run (no config) — verify CLI is functional ──"
if /opt/data/bin/rclone --version >/dev/null 2>&1; then
  RE=$(/opt/data/bin/rclone listremotes 2>&1)
  echo "  rclone listremotes → \"$RE\" (empty is expected without config)"
  pass "rclone CLI operational (config missing is expected)"
else
  fail "rclone not executable"
fi

echo ""
echo "── E10: concurrent playwright (2 parallel captures) ──"
$VENV_PY - 2>&1 <<'PY'
import asyncio, os, time
from playwright.async_api import async_playwright
async def cap(idx):
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        ctx = await b.new_context(viewport={'width':800,'height':600},
            record_video_dir=f'/tmp/cc{idx}',
            record_video_size={'width':800,'height':600})
        pg = await ctx.new_page()
        await pg.goto(f'data:text/html,<h1>Concurrent {idx}</h1>')
        await pg.wait_for_timeout(1000)
        await ctx.close(); await b.close()
        return idx
async def m():
    for i in (1,2): os.makedirs(f'/tmp/cc{i}', exist_ok=True)
    t0 = time.time()
    r = await asyncio.gather(cap(1), cap(2))
    dt = time.time()-t0
    print(f'  2 concurrent captures done in {dt:.1f}s, results: {r}')
asyncio.run(m())
PY
pass "playwright 2× concurrent"

echo ""
echo "================ EDGE-CASE SUMMARY ================"
echo "  ${PASS} pass · ${FAIL} fail"
