# GTA 6 Clipper

**Fully automated GTA 6 shorts machine.** It watches the biggest GTA 6 channels, grabs the fastest-rising new video, cuts it into vertical 9:16 clips with captions and hooks, and schedules them to YouTube Shorts, TikTok and Instagram Reels. It runs on your own PC, 24/7, with zero paid software.

```
GTA 6 channels  ->  pick trending video  ->  AI finds best moments  ->  9:16 clips + captions  ->  auto-post across the day
 (every 10 min)      (skips live streams)     (Gemini + Whisper GPU)     (OpenShorts engine)        (Upload-Post)
```

One script. One install command. After that it runs by itself.

---

## Contents

1. [What you need](#1-what-you-need)
2. [Prepare Windows (one time)](#2-prepare-windows-one-time)
3. [Get your free keys](#3-get-your-free-keys)
4. [Install](#4-install)
5. [Start the autopilot](#5-start-the-autopilot)
6. [Daily commands](#6-daily-commands)
7. [Control it with Gemini CLI](#7-control-it-with-gemini-cli)
8. [Auto-start when your PC turns on](#8-auto-start-when-your-pc-turns-on)
9. [Settings](#9-settings)
10. [Troubleshooting](#10-troubleshooting)
11. [FAQ](#11-faq)
12. [Disclaimer](#12-disclaimer)
13. [Use your PC as a GPU worker for a VPS](#13-use-your-pc-as-a-gpu-worker-for-a-vps-optional)

---

## 1. What you need

| Item | Notes |
|---|---|
| PC with NVIDIA GPU | RTX 3060 12 GB is perfect. 8 GB+ VRAM works. No GPU? It still runs on CPU, just slower. |
| Windows 10/11 or Linux | Windows uses WSL2 (Ubuntu inside Windows). |
| 40 GB free disk | Docker images, AI models and videos. |
| Gemini API key | Free. Picks the viral moments. |
| Upload-Post account | Free tier available. Posts the clips to your socials. Optional: without it you still get clips. |

---

## 2. Prepare Windows (one time)

Skip to step 3 if you are on Linux with Docker + NVIDIA drivers already set up.

**2.1 Update your NVIDIA driver**
Download the latest Game Ready or Studio driver from https://www.nvidia.com/Download/index.aspx and install it. Reboot.

**2.2 Install WSL2 + Ubuntu**
Open **PowerShell as Administrator** and run:
```powershell
wsl --install -d Ubuntu
```
Reboot when asked. Ubuntu opens and asks you to create a username and password. Remember them.

**2.3 Install Docker Desktop**
1. Download from https://www.docker.com/products/docker-desktop/ and install.
2. Open Docker Desktop, go to **Settings > General**, make sure **Use the WSL 2 based engine** is ticked.
3. Go to **Settings > Resources > WSL Integration** and switch **Ubuntu** ON.
4. Click **Apply & restart**.

**2.4 Check the GPU works inside Docker**
Open the **Ubuntu** app and run:
```bash
nvidia-smi
docker run --rm --gpus all ubuntu:22.04 nvidia-smi -L
```
Both should show your GPU (for example `NVIDIA GeForce RTX 3060`). If yes, you are ready.

**2.5 Install the basics in Ubuntu**
```bash
sudo apt update && sudo apt install -y git curl python3 nano
```

---

## 3. Get your free keys

**Gemini API key (required)**
1. Go to https://aistudio.google.com/api-keys
2. Sign in with Google, click **Create API key**, copy it.

**Upload-Post (for auto-posting)**
1. Sign up at https://app.upload-post.com
2. Create a **profile** (for example `gta6clips`) and connect your TikTok, YouTube and Instagram accounts to it.
3. Go to https://app.upload-post.com/api-keys and copy your API key.
4. Note the **profile name**, you will need it.

**Telegram alerts (optional)**
1. In Telegram, message **@BotFather**, send `/newbot`, copy the bot token.
2. Message **@userinfobot** to get your chat id.
3. Send any message to your new bot once so it can DM you.

---

## 4. Install

In the **Ubuntu** app:

```bash
curl -fsSLo gta6.sh https://raw.githubusercontent.com/cassh100k/gta6-clipper/main/gta6.sh
bash gta6.sh install
```

The installer will:
1. Check your GPU, Docker and tools.
2. Ask for your Gemini key, Upload-Post key + profile, and Telegram (Enter skips any optional one).
3. Download the OpenShorts engine and configure it for your GPU (Whisper large-v3-turbo on CUDA).
4. Build everything. **First build takes 15 to 40 minutes.** Let it run.
5. Verify the engine and show which GTA 6 video it would clip first.

When it finishes you will see `INSTALLED -> /home/<you>/gta6-clipper`.

Everything lives in `~/gta6-clipper`:
```
gta6-clipper/
  gta6.sh          the control script
  config.env       your keys + settings
  watchlist.json   GTA 6 channels it watches
  autopilot.py     the automation brain
  GEMINI.md        instructions for Gemini CLI
  openshorts/      the clipping engine
  data/            state, logs
```

---

## 5. Start the autopilot

```bash
~/gta6-clipper/gta6.sh start
```

That's it. Every 10 minutes it will:
1. Check every GTA 6 channel for new uploads (only titles about GTA 6 / GTA VI).
2. Skip videos that are still live or upcoming, skip Shorts, skip anything already clipped.
3. Pick the video gaining views fastest.
4. Make 5 vertical clips (20 to 60 s) with burned captions and a hook title.
5. Schedule them through Upload-Post, spread evenly across the day (6 posts per day by default), with the creator credited and GTA 6 hashtags.
6. Ping you on Telegram (if set up).

Review or edit any clip by hand in the dashboard: **http://localhost:5175**

---

## 6. Daily commands

Shortcut (optional): `echo 'alias gta6=~/gta6-clipper/gta6.sh' >> ~/.bashrc && source ~/.bashrc`

| Command | What it does |
|---|---|
| `gta6 status` | Engine health, GPU, posting on/off, current job, last results |
| `gta6 start` / `gta6 stop` | Start or stop the autopilot (`stop all` also stops the engine) |
| `gta6 dry` | Show which video it would clip next, without doing it |
| `gta6 once` | Run one step right now |
| `gta6 submit <youtube-url>` | Clip a specific video now |
| `gta6 logs` | Live autopilot log (Ctrl+C to exit) |
| `gta6 enginelogs` | Live engine log |
| `gta6 config` | Open settings in an editor |
| `gta6 config set KEY VALUE` | Change one setting, for example `gta6 config set POSTS_PER_DAY 8` |
| `gta6 channels list` | Show watched channels |
| `gta6 channels add <UC id> "<name>"` | Watch another channel |
| `gta6 channels remove <UC id>` | Stop watching a channel |
| `gta6 proxies` | Refresh the backup proxy list now |
| `gta6 update` | Update the engine to the latest version |
| `gta6 worker` | Engine only, no autopilot (when a VPS drives your GPU, see section 13) |

**Finding a channel id (UC...):** open the channel on YouTube, View Page Source, search `"externalId"` or `channel_id=`.

---

## 7. Control it with Gemini CLI

Talk to your automation in plain English using your Google / Gemini account.

```bash
cd ~/gta6-clipper
npx @google/gemini-cli
```
(Needs Node.js: `curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - && sudo apt install -y nodejs`)

Sign in with your Google account when asked. Gemini reads `GEMINI.md` and knows every command. Try:
- "status"
- "what will you clip next?"
- "the last job failed, find out why and fix it"
- "post 8 clips a day instead of 6"
- "clip this video: https://youtube.com/watch?v=..."

---

## 8. Auto-start when your PC turns on

1. Docker Desktop: **Settings > General > Start Docker Desktop when you sign in** (tick it).
2. Open **Task Scheduler** > **Create Task**:
   - **General:** name `GTA6 Clipper`, tick *Run only when user is logged on*.
   - **Triggers:** New > *At log on*. Add a 1 minute delay.
   - **Actions:** New > Program: `wsl.exe`
     Arguments: `-d Ubuntu -u YOUR_UBUNTU_USERNAME -- bash -lc "~/gta6-clipper/gta6.sh start"`
   - **Conditions:** untick *Start only if on AC power*.
3. Keep the PC from sleeping: **Settings > System > Power > Sleep = Never**.

---

## 9. Settings

Edit with `gta6 config` (or `gta6 config set KEY VALUE`).

| Setting | Default | Meaning |
|---|---|---|
| `GEMINI_API_KEY` | | Your Gemini key |
| `GEMINI_MODEL` | `gemini-3.1-flash-lite` | Model that picks moments |
| `MOMENT_PICKER` | `gemini` | `gemini` or `ollama` (100% local, uses ~5 GB VRAM) |
| `UPLOAD_POST_API_KEY` | | Upload-Post key (empty = posting off) |
| `UPLOAD_POST_USER` | | Upload-Post profile name |
| `PLATFORMS` | `youtube,tiktok,instagram` | Where to post |
| `POSTS_PER_DAY` | `6` | Posts are spread evenly over 24 h |
| `FIRST_POST_DELAY_MIN` | `30` | Wait before the first post of a batch |
| `TARGET_CLIPS` | `5` | Clips per video |
| `CLIP_MIN` / `CLIP_MAX` | `20` / `60` | Clip length in seconds |
| `MAX_SOURCE_MINUTES` | `90` | Only process the first N minutes of long videos |
| `MAX_AGE_HOURS` | `72` | Ignore videos older than this |
| `TITLE_FILTER` | `gta ?(6\|vi)...` | Only clip titles matching this (regex) |
| `HASHTAGS` | `#GTA6 #GTAVI ...` | Added to every caption |
| `CREDIT_SOURCE` | `1` | Adds "Credit: <creator>" to captions |
| `STEP_MINUTES` | `10` | How often the autopilot runs |
| `USE_PUBLIC_PROXIES` | `1` | Free proxies as backup if YouTube blocks your IP |
| `PROXY_REFRESH_HOURS` | `3` | How often to refresh proxies |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` | | Telegram alerts |

**Default channels:** Rockstar Games, MrBossFTW, Typical Gamer, GTA Series Videos, DarkViperAU, Kai Cenat Live, IShowSpeed, Kwebbelkop, TGG, GTANet, CaseOh, Ninja. Edit with `gta6 channels`.

---

## 10. Troubleshooting

| Problem | Fix |
|---|---|
| `Docker cannot see the GPU` | Update NVIDIA driver + Docker Desktop, reboot, re-run step 2.4. |
| Build fails with `npm error ... canvas` or `Request timed out` | Network hiccup. The script retries 3x automatically; if all fail just run `bash gta6.sh install` again (it resumes). |
| `engine not ready` | Wait 1 to 2 minutes after start. Still down? `gta6 enginelogs` and `gta6 stop all && gta6 start`. |
| `GEMINI_API_KEY missing` | `gta6 config set GEMINI_API_KEY <key>` |
| `no fresh GTA 6 video right now` | Normal. Nothing new in the last 72 h, or all already clipped. Try `gta6 submit <url>`. |
| Job failed: `Sign in to confirm you're not a bot` | YouTube is blocking your IP. Run `gta6 proxies`, then `gta6 once`. |
| Clips made but nothing posted | `gta6 status` shows `posting: OFF` until `UPLOAD_POST_API_KEY` and `UPLOAD_POST_USER` are set. Check accounts are connected in Upload-Post. |
| `CUDA devices: 0` | GPU not passed to Docker. Re-check step 2.4, then `bash gta6.sh install` again. |
| Very slow | No GPU = CPU mode. Check `gta6 status` shows `gpu: CUDA`. |
| Out of disk | Old clips live in `~/gta6-clipper/openshorts/output`. Delete old job folders. |

Still stuck? Open Gemini CLI in `~/gta6-clipper` and say "the clipper is broken, diagnose it".

---

## 11. FAQ

**Does it cost anything?** The software is free. Gemini free tier is enough for normal use. Upload-Post has a free tier; heavy posting may need their paid plan.

**How long does one video take?** On an RTX 3060 about 5 to 15 minutes for a 1 hour source. CPU-only: 30 to 90 minutes.

**Can I clip something other than GTA 6?** Yes: change `TITLE_FILTER` and the channels. Set `TITLE_FILTER` to `.` to accept every title.

**Does it re-clip the same video?** No. Every video is remembered in `data/state.json`.

**What about live streams?** Skipped while live. Once the stream ends and the VOD is up, it gets picked like any other video.

**Can I run it on a server instead of my PC?** Yes, any Linux box with Docker. Without a GPU it switches to CPU mode automatically.

---

## 13. Use your PC as a GPU worker for a VPS (optional)

Want an always-on server to be the brain, but your home GPU to do the heavy clipping? Link them with **Tailscale** (free private network, no port forwarding, nothing exposed to the internet).

```
VPS (always on)                         Your PC (RTX 3060)
picks GTA 6 videos  --- Tailscale --->  OpenShorts engine clips them
schedules posts     <-- results -----   (home IP = fewer YouTube blocks)
```

**On the PC**
1. Install the clipper normally (sections 2 to 4).
2. Install Tailscale for Windows: https://tailscale.com/download/windows and sign in.
3. Run the engine in worker mode (Ubuntu app):
   ```bash
   ~/gta6-clipper/gta6.sh worker
   ```
4. Share the engine with your tailnet only (PowerShell):
   ```powershell
   tailscale serve --bg --tcp 8000 tcp://127.0.0.1:8000
   ```
5. Note the PC name shown in the Tailscale app (for example `gaming-pc`).

**On the VPS**
1. Install Tailscale and join the **same** account:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up --hostname=vps-clipper --accept-dns=false
   ```
   Open the login link it prints and approve.
2. Test the link:
   ```bash
   curl http://gaming-pc:8000/health/ready
   ```
3. Point the VPS autopilot at the PC first, with its own engine as fallback. With this repo's script on the VPS, use `gta6.sh submit`/`once` against the PC by setting `API` in `autopilot.py` to `http://gaming-pc:8000`.

When the PC is off, jobs wait or fall back to the VPS engine. Do **not** run `gta6.sh start` on the PC in worker mode, or both machines will pick and post videos.

## 12. Disclaimer

This tool clips videos made by other creators. Reposting someone else's content can lead to **Content ID claims, "reused content" demonetization or copyright strikes** on your accounts. The safest path is clipping creators who allow it or run paid clipping campaigns, always crediting them (on by default). You are responsible for what you post.

Built on [OpenShorts](https://github.com/mutonby/openshorts) (MIT). This repo: MIT.
