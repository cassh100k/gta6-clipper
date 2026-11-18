#!/usr/bin/env bash
# =====================================================================================
#  GTA 6 CLIPPER  ·  fully automated long-video -> vertical shorts -> auto-post pipeline
# -------------------------------------------------------------------------------------
#  Engine : OpenShorts (self-hosted, MIT) in Docker. Whisper on your NVIDIA GPU
#           (RTX 3060 12GB: large-v3-turbo fp16), CPU fallback if no GPU.
#  Brain  : Gemini picks the viral moments, titles and hooks (your AI Studio key).
#  Loop   : every STEP_MINUTES: watch GTA 6 channels -> pick fastest-rising new upload
#           (skips live/upcoming streams + Shorts) -> clip -> schedule posts via
#           Upload-Post spread across the day -> Telegram ping (optional).
#  Proxies: free public proxies harvested + YouTube-verified, used only as fallback.
#
#  Run inside Ubuntu (WSL2 on Windows, or native Linux):
#     curl -fsSLo gta6.sh https://raw.githubusercontent.com/cassh100k/gta6-clipper/main/gta6.sh && bash gta6.sh install
#  Then:  ~/gta6-clipper/gta6.sh start | stop | status | once | submit <url> | logs
#         ~/gta6-clipper/gta6.sh proxies | config | channels | update | worker | help
# =====================================================================================
set -euo pipefail
BASE="${GTA6_HOME:-$HOME/gta6-clipper}"
OS_DIR="$BASE/openshorts"; DATA="$BASE/data"; CONF="$BASE/config.env"
SELF="$BASE/gta6.sh"; PIDF="$DATA/autopilot.pid"; LOG="$DATA/autopilot.log"
API="http://127.0.0.1:8000"

c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_b='\033[1;36m'; c_0='\033[0m'
say(){ printf "\n${c_g}==> %s${c_0}\n" "$*"; }
info(){ printf "${c_b}  - %s${c_0}\n" "$*"; }
warn(){ printf "${c_y}  ! %s${c_0}\n" "$*"; }
die(){ printf "\n${c_r}ERROR: %s${c_0}\n" "$*"; exit 1; }
getc(){ grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }
setc(){ local k="$1" v="$2"; grep -vE "^$k=" "$CONF" > "$CONF.tmp" || true; printf '%s="%s"\n' "$k" "$v" >> "$CONF.tmp"; mv "$CONF.tmp" "$CONF"; chmod 600 "$CONF"; }
has_gpu(){ command -v nvidia-smi >/dev/null && docker run --rm --gpus all ubuntu:22.04 nvidia-smi -L >/dev/null 2>&1; }
dc(){ (cd "$OS_DIR" && docker compose "$@"); }

# ------------------------------------------------------------------ config
write_default_config(){
  [ -f "$CONF" ] && return 0
  cat > "$CONF" <<'EOF'
# ===== GTA 6 CLIPPER CONFIG (edit with: gta6.sh config) =====
# Gemini key: https://aistudio.google.com/api-keys  (free tier works; paid tier = higher limits)
GEMINI_API_KEY=""
GEMINI_MODEL="gemini-3.1-flash-lite"
# Moment picker: gemini (best quality) | ollama (100% local, uses ~5GB VRAM)
MOMENT_PICKER="gemini"
# Upload-Post: https://app.upload-post.com/api-keys ; connect TikTok/YouTube/Instagram to a profile there
UPLOAD_POST_API_KEY=""
UPLOAD_POST_USER=""
PLATFORMS="youtube,tiktok,instagram"
POSTS_PER_DAY="6"
FIRST_POST_DELAY_MIN="30"
# Clip shape
TARGET_CLIPS="5"
CLIP_MIN="20"
CLIP_MAX="60"
MAX_SOURCE_MINUTES="90"
# Source selection
MAX_AGE_HOURS="72"
TITLE_FILTER="gta ?(6|vi)\b|grand theft auto (6|vi)\b"
HASHTAGS="#GTA6 #GTAVI #GrandTheftAuto #gaming #shorts"
CREDIT_SOURCE="1"
# Loop + network
STEP_MINUTES="10"
USE_PUBLIC_PROXIES="1"
PROXY_REFRESH_HOURS="3"
# Optional Telegram alerts (bot from @BotFather, chat id from @userinfobot)
TG_BOT_TOKEN=""
TG_CHAT_ID=""
EOF
  chmod 600 "$CONF"
}

write_watchlist(){
  [ -f "$BASE/watchlist.json" ] && return 0
  cat > "$BASE/watchlist.json" <<'EOF'
{"channels":[
 {"id":"UC6VcWc1rAoWdBCM0JxrRQ3A","name":"Rockstar Games","allowClip":true},
 {"id":"UC0PMQXAwF6O6aeTpv962miA","name":"MrBossFTW","allowClip":true},
 {"id":"UC2wKfjlioOCLP4xQMOWNcgg","name":"Typical Gamer","allowClip":true},
 {"id":"UCuWcjpKbIDAbZfHoru1toFg","name":"GTA Series Videos","allowClip":true},
 {"id":"UCV6mNrW8CrmWtcxWfQXy11g","name":"DarkViperAU","allowClip":true},
 {"id":"UCvCfpQXRXdJdL07pzTIA6Cw","name":"Kai Cenat Live","allowClip":true},
 {"id":"UCWsDFcIhY2DBi3GB5uykGXA","name":"IShowSpeed","allowClip":true},
 {"id":"UCfLuMSIDmeWRYpuCQL0OJ6A","name":"Kwebbelkop","allowClip":true},
 {"id":"UChLDRvS2OeJ0f5Xi2j7uofA","name":"TGG","allowClip":true},
 {"id":"UC68lxGdIkpVZMOMLbf7jQTA","name":"GTANet","allowClip":true},
 {"id":"UC63anZxfVGHUEmfBAf5w7pw","name":"CaseOh","allowClip":true},
 {"id":"UCAW-NpUFkMyCNrvRSSGIvDQ","name":"Ninja","allowClip":true}
]}
EOF
}

# OpenShorts .env is generated from config.env (keeps proxies line if present)
sync_engine_env(){
  local gpu="$1" proxies=""
  [ -f "$OS_DIR/.env" ] && proxies="$(grep -E '^STATIC_PROXY_URLS=' "$OS_DIR/.env" || true)"
  {
    echo "GEMINI_API_KEY=$(getc GEMINI_API_KEY)"
    echo "GEMINI_MODEL=$(getc GEMINI_MODEL)"
    echo "UPLOAD_POST_API_KEY=$(getc UPLOAD_POST_API_KEY)"
    echo "TRANSCRIBE_BACKEND=whisper"
    if [ "$gpu" = 1 ]; then
      echo "WHISPER_MODEL=large-v3-turbo"; echo "WHISPER_DEVICE=cuda"; echo "WHISPER_COMPUTE=float16"
      echo "ASR_GPU_CONCURRENCY=1"; echo "FFMPEG_ENCODER=auto"
    else
      echo "WHISPER_MODEL=small"; echo "WHISPER_DEVICE=cpu"; echo "WHISPER_COMPUTE=int8"; echo "FFMPEG_ENCODER=x264"
    fi
    if [ "$(getc MOMENT_PICKER)" = ollama ]; then
      echo "LLM_BASE_URL=http://ollama:11434/v1"; echo "LLM_MODEL=qwen2.5:7b"
    fi
    echo "MAX_CONCURRENT_JOBS=1"; echo "AUTO_LAYOUT=1"; echo "SUBTITLE_BAND_CHECK=0"
    echo "RATE_LIMIT_ENABLED=0"; echo "DIRECT_FIRST=1"
    [ -n "$proxies" ] && echo "$proxies"
  } > "$OS_DIR/.env"
  chmod 600 "$OS_DIR/.env"
}

write_override(){
  local gpu="$1" f="$OS_DIR/docker-compose.override.yml"
  {
    echo "services:"
    echo "  backend:"
    if [ "$gpu" = 1 ]; then
      printf '    build:\n      context: .\n      args:\n        GPU: "1"\n'
      printf '    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu, video]\n'
    fi
    printf '    env_file: .env\n    restart: unless-stopped\n    ports: !override\n      - "127.0.0.1:8000:8000"\n'
    printf '  frontend:\n    ports: !override\n      - "127.0.0.1:5175:5173"\n'
    printf '  renderer:\n    ports: !override\n      - "127.0.0.1:3100:3100"\n'
    if [ "$(getc MOMENT_PICKER)" = ollama ]; then
      printf '  ollama:\n    image: ollama/ollama\n    container_name: openshorts-ollama\n    restart: unless-stopped\n'
      printf '    environment:\n      - OLLAMA_CONTEXT_LENGTH=16384\n    volumes:\n      - ollama_models:/root/.ollama\n'
      [ "$gpu" = 1 ] && printf '    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n'
      printf 'volumes:\n  ollama_models:\n'
    fi
  } > "$f"
  dc config --quiet || die "docker-compose override invalid"
}

# ------------------------------------------------------------------ autopilot (python, stdlib only)
write_autopilot(){
cat > "$BASE/autopilot.py" <<'PYEOF'
#!/usr/bin/env python3
"""GTA 6 clipping autopilot. One state-machine step per call; safe to run from a loop or cron.
   python3 autopilot.py step|status|submit <url>|proxies|dry"""
import json, os, re, sys, time, random, subprocess, html, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor
BASE = os.path.dirname(os.path.abspath(__file__)); DATA = os.path.join(BASE, "data")
STATE = os.path.join(DATA, "state.json"); API = "http://127.0.0.1:8000"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36"}
os.makedirs(DATA, exist_ok=True)

def cfg():
    c = {}
    for l in open(os.path.join(BASE, "config.env"), encoding="utf-8"):
        m = re.match(r'^([A-Z_]+)=(.*)$', l.strip())
        if m: c[m[1]] = m[2].strip().strip('"')
    return c
C = cfg(); I = lambda k, d: int(C.get(k) or d)
def log(*a): print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)
def load(p, d):
    try: return json.load(open(p))
    except Exception: return d
def save(p, o):
    json.dump(o, open(p + ".tmp", "w"), indent=1); os.replace(p + ".tmp", p)

def http(url, data=None, headers=None, timeout=60, method=None):
    h = dict(UA); h.update(headers or {})
    body = json.dumps(data).encode() if data is not None else None
    if body is not None: h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r: return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode("utf-8", "replace")

def api(path, data=None, timeout=60):
    h = {"X-Gemini-Key": C["GEMINI_API_KEY"]} if C.get("GEMINI_API_KEY") else {}
    s, t = http(API + path, data, h, timeout)
    try: j = json.loads(t)
    except Exception: j = {"raw": t}
    if s >= 400: raise RuntimeError(f"{path} {s}: {str(j.get('detail', t))[:300]}")
    return j

def notify(text):
    log("[notify]", re.sub(r"<[^>]+>", "", text).replace("\n", " | ")[:300])
    tok, chat = C.get("TG_BOT_TOKEN"), C.get("TG_CHAT_ID")
    if tok and chat:
        try: http(f"https://api.telegram.org/bot{tok}/sendMessage",
                  {"chat_id": chat, "text": text[:3900], "parse_mode": "HTML", "disable_web_page_preview": True}, timeout=20)
        except Exception as e: log("telegram failed", e)
E = lambda s: html.escape(str(s))

def engine_ready():
    try: return http(API + "/health/ready", timeout=5)[0] == 200
    except Exception: return False

# ---------- source picking
def pick_video(state):
    W = load(os.path.join(BASE, "watchlist.json"), {"channels": []})
    flt = re.compile(C.get("TITLE_FILTER") or ".", re.I); now = time.time(); cands = []
    for ch in [c for c in W["channels"] if c.get("allowClip")]:
        try: _, x = http(f"https://www.youtube.com/feeds/videos.xml?channel_id={ch['id']}", timeout=20)
        except Exception as e: log("feed fail", ch.get("name"), e); continue
        for e in x.split("<entry>")[1:]:
            g = lambda p: (re.search(p, e) or [None, ""])[1]
            vid, title = g(r"<yt:videoId>([^<]+)"), html.unescape(g(r"<title>([^<]+)"))
            link, views = g(r'<link rel="alternate" href="([^"]+)'), int(g(r'views="(\d+)"') or 0)
            try: pub = time.mktime(time.strptime(g(r"<published>([^<+]+)")[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
            except Exception: continue
            age_h = (now - pub) / 3600
            if not vid or vid in state["done"] or age_h > I("MAX_AGE_HOURS", 72): continue
            if "/shorts/" in link or re.search(r"#shorts?\b", title, re.I) or not flt.search(title): continue
            cands.append({"id": vid, "title": title, "ch": ch.get("name", ""), "vph": views / max(0.5, age_h),
                          "url": f"https://www.youtube.com/watch?v={vid}"})
    cands.sort(key=lambda c: -c["vph"])
    for c in cands[:10]:
        try:
            _, page = http(c["url"], timeout=20)
            if re.search(r'"isLiveNow":true|"isUpcoming":true|"isLive":true', page):
                log("skip live/upcoming:", c["title"][:70]); continue
        except Exception: pass
        return c
    return None

# ---------- posting
def schedule_posts(cur, clips, state):
    key, user = C.get("UPLOAD_POST_API_KEY"), C.get("UPLOAD_POST_USER")
    if not key or not user: return "clips ready in dashboard; auto-posting OFF (set UPLOAD_POST_API_KEY + UPLOAD_POST_USER)"
    plats = [p.strip() for p in (C.get("PLATFORMS") or "youtube").split(",") if p.strip()]
    gap = 24 * 3600 / max(1, I("POSTS_PER_DAY", 6))
    t = max(time.time() + I("FIRST_POST_DELAY_MIN", 30) * 60, state.get("next_slot", 0)); out = []
    for i, clip in enumerate(clips):
        desc = clip.get("video_description_for_tiktok") or clip.get("video_description_for_instagram") or clip.get("title", "")
        if C.get("CREDIT_SOURCE", "1") == "1": desc += f"\n\nCredit: {cur['ch']}"
        desc = (desc + "\n" + C.get("HASHTAGS", "")).strip()
        when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
        try:
            api("/api/social/post", {"job_id": cur["job_id"], "clip_index": i, "api_key": key, "user_id": user,
                "platforms": plats, "title": (clip.get("title") or "GTA 6")[:95], "description": desc[:2000],
                "scheduled_date": when, "timezone": "UTC"})
            out.append(f"#{i+1} {when[5:16].replace('T',' ')}Z"); t += gap
        except Exception as e: out.append(f"#{i+1} FAILED {str(e)[:80]}")
    state["next_slot"] = t
    return "scheduled " + ", ".join(out)

# ---------- state machine
def step(manual_url=None, dry=False):
    state = load(STATE, {"done": {}, "current": None, "history": [], "next_slot": 0})
    cur = state.get("current")
    if cur:
        try: st = api(f"/api/status/{cur['job_id']}")
        except Exception as e:
            if "404" in str(e) or time.time() - cur["at"] > 6 * 3600:
                state["done"][cur["vid"]] = "lost"; state["current"] = None; save(STATE, state)
                notify(f"⚠️ Clip job lost: {E(cur['title'])}")
            else: log("engine unreachable, retry later:", e)
            return
        if st.get("status") == "completed":
            clips = (st.get("result") or {}).get("clips") or []
            msg = schedule_posts(cur, clips, state) if clips else "no clips produced"
            state["done"][cur["vid"]] = f"completed:{len(clips)}"
            state["history"] = ([{**cur, "clips": len(clips), "msg": msg, "end": time.time()}] + state["history"])[:100]
            state["current"] = None; save(STATE, state)
            names = "\n".join(f"{i+1}. {E(c.get('title','clip'))}" for i, c in enumerate(clips))
            notify(f"✅ <b>{len(clips)} GTA 6 clips</b> from {E(cur['ch'])}: {E(cur['title'])}\n{names}\n{E(msg)}")
        elif st.get("status") == "failed" or time.time() - cur["at"] > 6 * 3600:
            why = " | ".join((st.get("logs") or [])[-3:])[:400]
            state["done"][cur["vid"]] = "failed"; state["current"] = None; save(STATE, state)
            notify(f"❌ Clip job failed: {E(cur['title'])}\n<code>{E(why)}</code>")
        else: log("job", cur["job_id"][:8], st.get("status"), "|", cur["title"][:60])
        return
    if not engine_ready(): return log("engine not ready (docker up?)")
    if not C.get("GEMINI_API_KEY") and C.get("MOMENT_PICKER") != "ollama": return log("GEMINI_API_KEY missing: run gta6.sh config")
    if manual_url:
        m = re.search(r"(?:v=|youtu\.be/|shorts/|live/)([\w-]{11})", manual_url)
        v = {"id": m[1] if m else manual_url, "title": manual_url, "ch": "manual", "url": manual_url}
    else:
        v = pick_video(state)
    if not v: return log("no fresh GTA 6 video right now")
    if dry: return log("[dry] would clip:", v["ch"], "|", v["title"], "|", v["url"])
    j = api("/api/process", {"url": v["url"], "acknowledged": True, "output_format": "vertical",
        "target_clips": I("TARGET_CLIPS", 5), "clip_min_seconds": I("CLIP_MIN", 20), "clip_max_seconds": I("CLIP_MAX", 60),
        "auto_hook": True, "captions": True, "max_minutes": I("MAX_SOURCE_MINUTES", 90)})
    state["current"] = {"vid": v["id"], "title": v["title"], "ch": v["ch"], "url": v["url"], "job_id": j["job_id"], "at": time.time()}
    state["done"][v["id"]] = "submitted"; save(STATE, state)
    notify(f"🎬 <b>Clipping</b> {E(v['ch'])}: {E(v['title'])}\n{v['url']}")

# ---------- public proxies (fallback only; DIRECT_FIRST=1 tries your own IP first)
LISTS = [("http", "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt"),
         ("socks5", "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/socks5/data.txt"),
         ("http", "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"),
         ("socks5", "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt"),
         ("http", "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt"),
         ("socks5", "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt"),
         ("http", "https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text")]
def _curl(args, t):
    try: return subprocess.run(["curl", "-s", "-m", str(t)] + args, capture_output=True, text=True, timeout=t + 5).stdout
    except Exception: return ""
def proxies(keep=15):
    if C.get("USE_PUBLIC_PROXIES", "1") != "1": return log("public proxies disabled")
    cand = set()
    for pfx, u in LISTS:
        for l in _curl([u], 30).splitlines():
            l = l.strip()
            if re.fullmatch(r"\d+\.\d+\.\d+\.\d+:\d+", l): l = f"{pfx}://{l}"
            if re.fullmatch(r"(http|socks5)://\d+\.\d+\.\d+\.\d+:\d+", l): cand.add(l.replace("socks5://", "socks5h://"))
    cand = random.sample(sorted(cand), min(6000, len(cand))); log("proxy candidates:", len(cand))
    def t1(p):
        o = _curl(["-o", "/dev/null", "-w", "%{http_code} %{time_total}", "-x", p, "https://www.youtube.com/generate_204"], 8).split()
        return (p, float(o[1])) if o and o[0] == "204" else None
    with ThreadPoolExecutor(250) as ex: s1 = sorted([r for r in ex.map(t1, cand) if r], key=lambda r: r[1])[:300]
    def t2(r):
        b = _curl(["-x", r[0], "-A", UA["User-Agent"], "https://www.youtube.com/watch?v=jNQXAC9IVRw"], 15)
        return r if '"playabilityStatus":{"status":"OK"' in b else None
    with ThreadPoolExecutor(100) as ex: good = sorted([r for r in ex.map(t2, s1) if r], key=lambda r: r[1])[:keep]
    log(f"proxies: reachable {len(s1)}, youtube-ok kept {len(good)}")
    if not good: return
    envf = os.path.join(BASE, "openshorts", ".env")
    lines = [l for l in open(envf).read().splitlines() if not l.startswith("STATIC_PROXY_URLS=")]
    new = "STATIC_PROXY_URLS=" + ",".join(p for p, _ in good)
    open(envf, "w").write("\n".join(lines + [new]) + "\n")
    if not load(STATE, {}).get("current"):
        subprocess.run(["docker", "compose", "up", "-d", "backend"], cwd=os.path.join(BASE, "openshorts"), capture_output=True)
        log("engine reloaded with fresh proxies")
    else: log("job in flight: proxies applied on next engine restart")

if __name__ == "__main__":
    a = sys.argv[1:] or ["step"]
    if a[0] == "step": step()
    elif a[0] == "dry": step(dry=True)
    elif a[0] == "submit" and len(a) > 1: step(manual_url=a[1])
    elif a[0] == "proxies": proxies()
    elif a[0] == "status":
        s = load(STATE, {"current": None, "history": [], "done": {}})
        print("current :", json.dumps(s.get("current"), indent=1) if s.get("current") else "idle")
        print("videos seen:", len(s.get("done", {})), "| next post slot:", time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(s.get("next_slot") or time.time())))
        for h in s.get("history", [])[:8]: print(f"  {time.strftime('%m-%d %H:%M', time.localtime(h['end']))}  {h['clips']} clips  {h['ch']}: {h['title'][:60]}  -> {h['msg'][:80]}")
    else: print(__doc__)
PYEOF
}

write_gemini_md(){
cat > "$BASE/GEMINI.md" <<'EOF'
# GTA 6 Clipper: operator notes for Gemini CLI

You operate a fully automated GTA 6 shorts pipeline on this machine. Work from this folder.

## Commands (always use these, never edit Docker by hand unless asked)
- `./gta6.sh status`   engine containers, current job, last results, next post slot
- `./gta6.sh start` / `./gta6.sh stop`   start/stop engine + autopilot loop
- `./gta6.sh once`     run one autopilot step now
- `./gta6.sh dry`      show which video would be clipped next (no action)
- `./gta6.sh submit <youtube-url>`   clip a specific GTA 6 video now
- `./gta6.sh logs`     tail autopilot log; `./gta6.sh enginelogs` for OpenShorts
- `./gta6.sh proxies`  refresh public fallback proxies
- `./gta6.sh channels add <UCxxxx channel id> "<name>"` / `channels list`
- `./gta6.sh config set KEY VALUE` (keys in config.env, e.g. POSTS_PER_DAY, PLATFORMS, TARGET_CLIPS)

## Rules
- Only GTA 6 content (TITLE_FILTER). Credit the source creator in every caption (CREDIT_SOURCE=1).
- Never print GEMINI_API_KEY / UPLOAD_POST_API_KEY / TG_BOT_TOKEN values.
- If a job fails, read `./gta6.sh logs` and `./gta6.sh enginelogs`, explain the cause, fix config, then `./gta6.sh once`.
- YouTube "Sign in to confirm you're not a bot": run `./gta6.sh proxies`, then retry.
- Daily check: `./gta6.sh status`; summarize clips made, posts scheduled, failures.
- Dashboard for manual review/edit: http://localhost:5175
EOF
}

# ------------------------------------------------------------------ commands
cmd_install(){
  say "1/8 Preflight"
  for b in git curl python3 docker; do command -v $b >/dev/null || die "$b missing. Ubuntu: sudo apt update && sudo apt install -y git curl python3  (Docker: Docker Desktop w/ WSL2 integration, or docs.docker.com/engine/install)"; done
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 missing"
  docker info >/dev/null 2>&1 || die "Docker daemon not running (start Docker Desktop)"
  case "$PWD" in /mnt/*) warn "you're on the Windows drive; installing to $BASE on the Linux side (much faster)";; esac
  local gpu=0
  if has_gpu; then gpu=1; info "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1) -> CUDA mode"
  else warn "no GPU visible to Docker -> CPU mode (slower). Windows: update NVIDIA driver + Docker Desktop."; fi
  mkdir -p "$BASE" "$DATA"
  [ "$(readlink -f "$0")" != "$SELF" ] && cp "$(readlink -f "$0")" "$SELF" 2>/dev/null || true; chmod +x "$SELF" 2>/dev/null || true
  echo "$gpu" > "$DATA/gpu"

  say "2/8 Config"
  write_default_config; write_watchlist
  if [ -t 0 ]; then
    [ -z "$(getc GEMINI_API_KEY)" ] && { read -rp "  Gemini API key (aistudio.google.com/api-keys): " k; [ -n "$k" ] && setc GEMINI_API_KEY "$k"; }
    [ -z "$(getc UPLOAD_POST_API_KEY)" ] && { read -rp "  Upload-Post API key (Enter = skip, clips only): " k; [ -n "$k" ] && setc UPLOAD_POST_API_KEY "$k"; }
    [ -n "$(getc UPLOAD_POST_API_KEY)" ] && [ -z "$(getc UPLOAD_POST_USER)" ] && { read -rp "  Upload-Post profile name: " k; [ -n "$k" ] && setc UPLOAD_POST_USER "$k"; }
    [ -z "$(getc TG_BOT_TOKEN)" ] && { read -rp "  Telegram bot token for alerts (Enter = skip): " k; [ -n "$k" ] && { setc TG_BOT_TOKEN "$k"; read -rp "  Telegram chat id: " k; setc TG_CHAT_ID "$k"; }; }
  fi
  [ -n "$(getc GEMINI_API_KEY)" ] || warn "no Gemini key yet: set later with  gta6.sh config set GEMINI_API_KEY <key>"

  say "3/8 OpenShorts engine"
  if [ -d "$OS_DIR/.git" ]; then git -C "$OS_DIR" pull --ff-only -q || warn "git pull skipped (local changes)"
  else git clone -q https://github.com/mutonby/openshorts.git "$OS_DIR"; fi
  mkdir -p "$OS_DIR"/{output,uploads,models,.cache/huggingface}; chmod -R a+rwX "$OS_DIR"/{output,uploads,models,.cache}

  say "4/8 Remotion pin (known renderer mismatch)"
  grep -q '"@remotion/renderer": "4.0.541"' "$OS_DIR/render-service/package.json" || \
    docker run --rm -v "$OS_DIR/render-service:/w" -w /w node:18-bookworm-slim npm install -s --package-lock-only --save-exact \
      @remotion/bundler@4.0.541 @remotion/renderer@4.0.541 remotion@4.0.541

  # canvas (bgutil dep) prebuilt download often times out -> give it build libs to compile from source
  python3 - "$OS_DIR/Dockerfile" <<'PYP'
import sys;p=sys.argv[1];s=open(p).read()
old='RUN git clone --depth 1 https://github.com/Brainicism/bgutil-ytdlp-pot-provider /opt/bgutil-provider \\\n'
if old in s and 'libcairo2-dev' not in s:
    s=s.replace(old,'RUN apt-get update && apt-get install -y --no-install-recommends build-essential pkg-config libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \\\n    && rm -rf /var/lib/apt/lists/*\nENV npm_config_fetch_timeout=600000 npm_config_fetch_retries=5\n'+old,1);open(p,'w').write(s);print('  - Dockerfile patched (canvas build libs)')
PYP

  say "5/8 Engine config"
  sync_engine_env "$gpu"; write_override "$gpu"; write_autopilot; write_gemini_md

  if [ "$(getc MOMENT_PICKER)" = ollama ]; then
    say "5b Ollama + qwen2.5:7b"
    dc up -d ollama; for i in $(seq 1 30); do docker exec openshorts-ollama ollama list >/dev/null 2>&1 && break; sleep 2; done
    docker exec openshorts-ollama ollama pull qwen2.5:7b
  fi

  say "6/8 Building (first time 15-40 min, grab a coffee)"
  local n; for n in 1 2 3; do dc up --build -d && break; [ $n = 3 ] && die "build failed 3x: see output above"; warn "build attempt $n failed (often a network timeout), retrying in 20s"; sleep 20; done

  say "7/8 YOLO model fix + restart"
  chmod a+rwx "$OS_DIR"
  [ -s "$OS_DIR/yolov8n.pt" ] || docker run --rm --entrypoint cat openshorts-backend /app/yolov8n.pt > "$OS_DIR/yolov8n.pt" 2>/dev/null || rm -f "$OS_DIR/yolov8n.pt"
  [ -f "$OS_DIR/yolov8n.pt" ] && chmod a+r "$OS_DIR/yolov8n.pt"
  dc restart >/dev/null

  say "8/8 Verify"
  local ok=0; for i in $(seq 1 60); do curl -fs "$API/health/ready" >/dev/null 2>&1 && { ok=1; break; }; sleep 5; done
  [ "$ok" = 1 ] && info "engine ready" || warn "engine not ready yet: check  gta6.sh enginelogs"
  [ "$gpu" = 1 ] && docker exec openshorts-backend python -c "import ctranslate2;print('  - CUDA devices:',ctranslate2.get_cuda_device_count())" || true
  (cd "$BASE" && python3 autopilot.py dry) || true
  [ "$(getc USE_PUBLIC_PROXIES)" = 1 ] && { info "harvesting fallback proxies in background"; (cd "$BASE" && nohup python3 autopilot.py proxies >> "$LOG" 2>&1 &) ; }

  cat <<EOF

$(printf "${c_g}INSTALLED${c_0}")  ->  $BASE
  Start autopilot :  $SELF start
  Watch it        :  $SELF status   |   $SELF logs
  Dashboard       :  http://localhost:5175
  Gemini CLI      :  cd $BASE && npx @google/gemini-cli    (sign in with your Google account; GEMINI.md teaches it the controls)
  Windows autostart (Task Scheduler > At log on > Program: wsl.exe):
     Arguments:  -d $(. /etc/os-release 2>/dev/null; echo "${NAME:-Ubuntu}" | cut -d' ' -f1) -u $USER -- bash -lc "$SELF start"
     (also tick Docker Desktop > Settings > "Start Docker Desktop when you sign in")
EOF
}

loop(){
  local step proxyh last_proxy=0
  while true; do
    step="$(getc STEP_MINUTES)"; proxyh="$(getc PROXY_REFRESH_HOURS)"
    (cd "$BASE" && python3 autopilot.py step) || true
    if [ "$(getc USE_PUBLIC_PROXIES)" = 1 ] && [ $(( $(date +%s) - last_proxy )) -ge $(( ${proxyh:-3} * 3600 )) ]; then
      (cd "$BASE" && python3 autopilot.py proxies) || true; last_proxy=$(date +%s)
    fi
    sleep $(( ${step:-10} * 60 ))
  done
}
running(){ [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

cmd_start(){
  [ -d "$OS_DIR" ] || die "not installed: bash gta6.sh install"
  dc up -d >/dev/null && info "engine up"
  if running; then info "autopilot already running (pid $(cat "$PIDF"))"; return; fi
  mkdir -p "$DATA"; nohup setsid bash "$SELF" _loop >> "$LOG" 2>&1 < /dev/null & echo $! > "$PIDF"
  info "autopilot started (pid $!), every $(getc STEP_MINUTES) min. Logs: $SELF logs"
}
cmd_stop(){ running && { kill -- -"$(cat "$PIDF")" 2>/dev/null || kill "$(cat "$PIDF")"; info "autopilot stopped"; }; rm -f "$PIDF"; [ "${1:-}" = all ] && dc stop; true; }
cmd_status(){
  printf "${c_b}autopilot:${c_0} "; running && echo "running (pid $(cat "$PIDF"))" || echo "stopped"
  printf "${c_b}engine   :${c_0} "; curl -fs "$API/health/ready" >/dev/null 2>&1 && echo ready || echo "down"
  dc ps --format '  {{.Name}}  {{.Status}}' 2>/dev/null || true
  printf "${c_b}gpu      :${c_0} "; [ "$(cat "$DATA/gpu" 2>/dev/null)" = 1 ] && echo CUDA || echo CPU
  printf "${c_b}posting  :${c_0} "; [ -n "$(getc UPLOAD_POST_API_KEY)" ] && echo "ON -> $(getc PLATFORMS), $(getc POSTS_PER_DAY)/day" || echo "OFF (no Upload-Post key)"
  printf "${c_b}proxies  :${c_0} %s\n" "$(grep -c . <<<"$(grep -E '^STATIC_PROXY_URLS=' "$OS_DIR/.env" 2>/dev/null | cut -d= -f2 | tr , '\n')")"
  (cd "$BASE" && python3 autopilot.py status)
}
cmd_config(){
  if [ "${1:-}" = set ] && [ $# -ge 3 ]; then setc "$2" "$3"; info "$2 updated"
  else "${EDITOR:-nano}" "$CONF"; fi
  sync_engine_env "$(cat "$DATA/gpu" 2>/dev/null || echo 0)"; write_override "$(cat "$DATA/gpu" 2>/dev/null || echo 0)"
  dc up -d >/dev/null 2>&1 && info "engine reloaded with new config" || true
}
cmd_channels(){
  case "${1:-list}" in
    list) python3 -c "import json;[print(('ON ' if c.get('allowClip') else 'off'),c['id'],c['name']) for c in json.load(open('$BASE/watchlist.json'))['channels']]";;
    add) [ $# -ge 3 ] || die "usage: channels add <UC... id> <name>"
         python3 - "$BASE/watchlist.json" "$2" "$3" <<'EOF'
import json,sys;p,i,n=sys.argv[1:];W=json.load(open(p))
W['channels']=[c for c in W['channels'] if c['id']!=i]+[{"id":i,"name":n,"allowClip":True}];json.dump(W,open(p,'w'),indent=1);print("added",n)
EOF
    ;;
    remove) python3 - "$BASE/watchlist.json" "$2" <<'EOF'
import json,sys;p,i=sys.argv[1:];W=json.load(open(p));W['channels']=[c for c in W['channels'] if c['id']!=i];json.dump(W,open(p,'w'),indent=1);print("removed",i)
EOF
    ;;
    *) die "channels list|add|remove";;
  esac
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0   # sourced: functions only
case "${1:-help}" in
  install) cmd_install;;
  start) cmd_start;;
  stop) cmd_stop "${2:-}";;
  restart) cmd_stop; cmd_start;;
  status) cmd_status;;
  worker) cmd_stop; dc up -d >/dev/null && info "WORKER MODE: engine up on 127.0.0.1:8000, local autopilot OFF (your VPS drives the jobs)"
          info "Expose it ONLY to your tailnet. Windows PowerShell:  tailscale serve --bg --tcp 8000 tcp://127.0.0.1:8000"
          info "Linux/WSL with tailscale:  sudo tailscale serve --bg --tcp 8000 tcp://127.0.0.1:8000"
          info "Then on the VPS:  curl http://<this-pc-tailscale-name>:8000/health/ready";;
  once) (cd "$BASE" && python3 autopilot.py step);;
  dry) (cd "$BASE" && python3 autopilot.py dry);;
  submit) [ -n "${2:-}" ] || die "usage: submit <youtube-url>"; (cd "$BASE" && python3 autopilot.py submit "$2");;
  proxies) (cd "$BASE" && python3 autopilot.py proxies);;
  logs) tail -n 60 -f "$LOG";;
  enginelogs) dc logs --tail 120 -f backend;;
  config) shift; cmd_config "$@";;
  channels) shift; cmd_channels "$@";;
  update) git -C "$OS_DIR" pull --ff-only && dc up --build -d;;
  _loop) loop;;
  *) sed -n '2,17p' "${BASH_SOURCE[0]}";;
esac
