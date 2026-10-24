# Phantom Control — User Guide

A native macOS app for monitoring, controlling, and offloading **Vision Research Phantom** high‑speed cameras (VEO, Flex, and similar) over Ethernet, with a built‑in professional monitoring suite and a phone/Stream Deck remote.

> **Tip:** This file is searchable. Press **⌘F** in your reader and type a term — e.g. *false color*, *zebra*, *partition*, *proxy*, *overlay*, *vectorscope*, *download*, *trigger*.

---

## Table of contents

1. [Quick start](#quick-start)
2. [Connecting to the camera](#connecting-to-the-camera)
3. [What works on which camera](#what-works-on-which-camera)
4. [The interface at a glance](#the-interface-at-a-glance)
5. [Recording & triggering](#recording--triggering)
6. [Playback & marking shots](#playback--marking-shots)
7. [Downloading / offloading footage](#downloading--offloading-footage)
8. [The monitoring bar (every tool explained)](#the-monitoring-bar)
9. [False Color (exposure assist)](#false-color-exposure-assist)
10. [Scopes — histogram, waveform, vectorscope](#scopes)
11. [Grid & Frame Guides](#grid--frame-guides)
12. [Image Overlay (onion‑skin)](#image-overlay-onion-skin)
13. [Video Out (external monitor)](#video-out-external-monitor)
14. [Flicker detection](#flicker-detection)
15. [LUTs](#luts)
16. [Projects, presets & where files go](#projects-presets--where-files-go)
17. [The phone remote](#the-phone-remote)
18. [Stream Deck / HTTP control](#stream-deck--http-control)
19. [Keyboard shortcuts](#keyboard-shortcuts)
20. [Troubleshooting](#troubleshooting)
21. [Glossary](#glossary)

---

## Quick start

1. Connect the camera to your Mac over **10 GbE / Ethernet** (directly or through a switch).
2. Launch **Phantom Control**. It discovers and connects to the camera automatically.
3. If you have an **SDI capture device** (e.g. an AVMATRIX USB‑C box) plugged in, the big viewer shows the live SDI feed. Otherwise it falls back to the camera's lower‑rate Ethernet preview.
4. Press **Space** to **Trigger** a recording, **C** to **Capture** (store the take), and **P** to play it back.
5. Mark the keeper region with **I** (in) and **O** (out), then **Download** to copy it to your project folder.

That's the whole loop: *roll → trigger → review → mark → download.*

---

## Connecting to the camera

- The app scans the local network on launch and connects to the first Phantom it finds.
- The **status bar** at the bottom shows the connection state, the camera body temperature, and the most recent log line.
- Communication is the Phantom **Ethernet text protocol** over TCP. No PCC, PVP, or Séance required.
- If the camera isn't found, check that it's on the same subnet and powered, then relaunch. (A camera that just booted can take a moment to answer.)

**Camera temperature:** shown in the status bar with a thermometer icon. It turns red at/above 65 °C — give the body a rest if you see that during long high‑frame‑rate sessions.

---

## What works on which camera

The app **probes each camera** when it connects and shows only the controls that body actually supports — so if a control isn't there, your model doesn't do it. Here's the practical rundown:

| Feature | Flex / Flex 4K | VEO | CineStation |
|---|---|---|---|
| Live monitor (SDI + Ethernet) | ✅ | ✅ | plays mag takes only |
| Record · trigger · partitions | ✅ | ✅ | — |
| Download RAM takes to the Mac | ✅ (Ethernet) | ✅ (faster on 10G) | — |
| Save a take to a **CineMag** | ✅ | downloads to Mac instead | — |
| Offload a **CineMag** (thumbnails, verify, proxy, DIT, trim) | ✅ from the camera | via a CineStation | ✅ over 10G |
| ISO / EI (1/3 stops) | ✅ (develop gain) | ✅ (Log mode locks it) | reads baked‑in values |
| White balance | ✅ | ✅ + Kelvin | reads baked‑in values |

**Rules of thumb**

- **Have a CineMag → save to the mag. No CineMag → download to the Mac.** The one‑tap **Save In→Out** does this for you, so a Flex keeps to the mag and a VEO downloads.
- **To offload a CineMag** you need the mag in a Phantom (**Open CineMag**) or in a **CineStation** (**Open CineStation**) — it's the same window either way.
- **Per‑take delete from a CineMag** can be ignored by the camera firmware (the app warns you); the reliable wipe is the **full erase**.
- **No‑shutter bodies** (e.g. the Flex 2K) can only black‑reference with the **lens capped** — the app reminds you after a frame‑rate change.
- **Best‑tested today:** live monitoring, RAM download, and CineMag offload (camera + CineStation) on the **Flex**. The VEO's CFast path is newer and less exercised — downloading to the Mac is the safe route there.

> This is **beta software**. It only ever *reads* from the camera and never changes firmware, so there's no way for it to damage the camera — but test features on non‑critical footage first, and keep a second copy of anything you can't reshoot.

---

## The interface at a glance

- **Viewer** (left/center) — the live image or playback, with all monitoring overlays drawn on top.
- **Viewer toolbar** (above the image) — Presets, Auto‑save, OSD, Cam Out, Overlay, Ramp, the keyboard‑shortcut reference, and more.
- **Monitoring bar** (below the toolbar) — the row of "pills": False Color, Peaking, Zebra, scopes, Grid, Guides, Video Out, Invert, Flip, Flicker, LUT.
- **Settings rail** (right) — project/shot naming, frame rate, shutter, recording and download controls. Drag its left edge to resize.
- **Partition strip** (bottom) — the camera's RAM partitions / cines. Drag its top edge to resize.
- **Status bar** (very bottom) — connection, temperature, log.

Panel sizes are **remembered across launches**.

### How the pills work (important)

Every tool in the monitoring bar is a **pill**:

- **Left‑click** = toggle the tool **on/off**. Active tools fill with the accent colour.
- **Right‑click** = open that tool's **settings** (a little pop‑up panel with sliders/options and an arrow at the top). Click anywhere outside to dismiss it.

Tools with no options (Invert, Flip H, Flip V) just toggle. The whole pill is clickable — there are no tiny targets.

---

## Recording & triggering

Phantom cameras record into a **circular RAM buffer**. You roll continuously and then "trigger" to keep the moment that just happened (or is about to, depending on trigger position).

- **Trigger** (Space) — fire the trigger; the camera captures the buffer around the trigger point.
- **Capture / Store** (C) — store the captured take into a cine slot / partition.
- **Stop & Save** — stop an in‑progress recording early while keeping the partial footage.
- **Clear RAM** — wipe the buffer to start fresh.
- **Frame rate & shutter** — set custom values from the rail. Shutter can be entered directly; the Flicker tool can even suggest a shutter to kill mains flicker (see below).
- **ISO / EI** — set your exposure index from the rail, in full **1/3‑stop** steps (…1250, 1600, 2000, 2500…). The app matches how *your* camera does EI (a develop gain on the Flex, named tone curves on the VEO), so you just pick a number. **HQ mode** locks EI to native on the Flex; **Log mode** locks it on the VEO.
- **Black Reference (CSR)** — runs the camera's black‑balance routine; do this after big temperature, frame‑rate, or exposure changes. **If your camera has no working shutter, you must cap the lens first** — there's no internal shutter to make black, so an uncapped black reference calibrates against the live image and ruins it.
- **White Balance** — set white balance from the rail. *Note:* on some cameras White Balance triggers an internal black reference, so cap the lens for that too.

> **Frame‑rate → black‑reference reminder.** The black shade is calibrated *per frame rate*, so when you change the frame rate a reminder pops up with a **Run Black Reference** button (cap the lens first). Redo it and your image stays clean.

**Overwrite protection:** the app warns you before overwriting a cine/partition that hasn't been downloaded yet, so you don't lose a take.

### Partitions

The camera's RAM can be split into multiple **partitions** (independent cines), so you can keep several takes in RAM at once. Set the partition count from the partition strip / rail; the app uses the correct command for your camera model (Flex re‑slices its RAM, VEO uses `partition N`).

> **Changing the partition count erases RAM** (the app confirms first). It's safe to go up or down at any time — the app clears RAM, lets the camera settle, and re‑slices cleanly, so the live picture won't scramble even if you drop from many partitions to few with takes still in RAM. **Save anything you want to keep first.**

### Auto‑save modes (hands‑free recording)

Three toggles on the viewer toolbar handle each triggered take for you, so you can keep shooting without babysitting downloads. Turn on **one**:

- **Auto‑save → Comp** — after every trigger, the app **downloads the take to this Mac** (a `.cine` in your project folder), then frees the partition. *The app does the work, over Ethernet.*
- **Auto‑save → Mag** — after every trigger, the app **saves the take onto the CineMag** in the camera (no download), then frees the partition. Right‑click to choose whether the RAM copy is cleared (re‑arm) or kept. *The app does the work, one take at a time.*
- **Continuous → Mag** — the **camera itself** saves each triggered partition to the CineMag and instantly re‑arms it, cycling through all your partitions non‑stop (trigger → save → re‑arm → roll). Fully hands‑free — it keeps going even if you close the app, and the setting persists on the camera. *Best for continuous high‑speed shooting; needs a CineMag.*

**The difference in one line:** the first two are the *app* saving take‑by‑take (to the Mac or the mag); the third is the *camera* running a continuous save‑and‑re‑arm loop on its own.

> **Camera differences:** the app auto‑adapts the low‑level details per body (partition commands, CineMag frame reads, the EI method) so the modes behave the same across cameras. **Continuous → Mag** relies on the camera's own continuous‑record firmware — confirmed on the Flex 4K; on other bodies its availability depends on the firmware.

---

## Playback & marking shots

- **Play / Pause** — **P**.
- **Step one frame** — **←** / **→**.
- **Go Live** — **L** (return to the live image).
- **Mark In** — **I**; **Mark Out** — **O**. This sets the keeper region that gets saved/downloaded.
- **Reset In/Out** — clears the marks back to the full clip.
- **Go to frame** — type a frame number to jump.
- **Auto‑play / "go to, then play"** — jumps to a hero frame and rolls from there.

> **Note on scrubbing:** the camera plays back its RAM over its own output. The playback range follows the marked region; because of a hardware limitation, the playhead can't be freely repositioned *within* a range independently of that range — so "go to a frame" works by re‑cueing, then playing.

---

## Downloading / offloading footage

You can keep footage two ways: **download it to the Mac** over Ethernet, or **save it to a CineMag** (camera‑side, near‑instant, no download). Mark **In/Out** on the deck first; files are named from your **Project** and **Shot** names and auto‑increment so nothing is overwritten.

- **Save Proxy** — write a proxy/preview `.mov` alongside the master.
- **Auto‑save** — when enabled, every triggered shot is offloaded automatically and the partition re‑arms for the next take. Great for run‑and‑gun. You can auto‑save **to the computer** *or* **to the CineMag**.

See [Projects, presets & where files go](#projects-presets--where-files-go) for the folder layout.

### One‑tap keep (Save In→Out)

With a stored RAM clip on the deck, a **Save** button sits right by the in/out frame numbers — and the same option is on the **right‑click menu of the green timeline**. It picks the destination for you:

- **CineMag present →** *Save In→Out to CineMag* (instant camera‑side copy, no download).
- **No CineMag →** *Download In→Out to Mac.*

So a Flex with a mag keeps to the mag and a VEO downloads to the computer — no toggle to think about. The full **Download** / **Save to CineMag** buttons in the **Save** tab are always there if you want to force one or the other.

### CineMag offload — from the camera OR a CineStation

Footage on a CineMag can be pulled off with the same full workflow from **either** device:

- **Open CineMag** (Save tab) — the camera‑side offload window.
- **Open CineStation** (Save tab / File menu) — the same window for a CineStation on its own 10G port, so you can offload a mag without tying up the camera.

Both windows give every take a **thumbnail** (from the *middle* of the clip, with a Finder‑style **size slider**) and, per take: **download one** or **Download All**, **verify (MD5)**, a **proxy `.mov`**, a **metadata sidecar**, and a one‑page **DIT report** (the batch also writes a combined report). Each take has an in‑window **trimmer** — scrub, mark in/out, and download just the trimmed range (handy when you auto‑saved a whole game and only want the highlights).

> **Deleting from a CineMag.** You can *play* and *download* any take freely. A **single‑take delete** is offered, but some camera firmware ignores it — the app checks afterward and warns you if it was a no‑op. The reliable way to clear a mag is the **full erase** (type ERASE to confirm). Treat a CineMag as append‑only footage you offload, then wipe as a whole.

### Download verification (checksums)

**Verify downloads (MD5 checksum)** — in **Download ▸ Advanced**, on by default — adds error‑checking to every offload:

1. After the `.cine` is written, it's **re‑opened and checked**: the header must parse, the **frame count must match** what was requested, and the **last frame must read back** (catches a truncated/short download).
2. The file is **MD5‑hashed**, and the hash is written two ways: a `<clip>.cine.md5` sidecar and an appended line in a project‑level **`Checksums.md5`** manifest.
3. A clip is only marked **safe** (green / no overwrite warning) **after it verifies**, and with auto‑download the camera partition is **not erased unless the copy verified** — so a bad offload can never quietly delete your only copy.

The manifest is standard **md5sum** format, so it opens directly in **ShotPut Pro** or verifies from Terminal with `md5sum -c Checksums.md5`. That hash travels with the clip, so every later copy (to a RAID, the cloud, etc.) can be re‑verified against the original download.

It also writes a project‑level **`<Project>.mhl`** (Media Hash List 1.1 XML) — the standard offload hand‑off that imports into **ShotPut Pro**, **Silverstack**, **YoYotta**, etc. Each download appends a `<hash>` entry (file, size, MD5, dates) under one `<hashlist>`.

### Metadata (Download ▸ Metadata)

Capture One‑style production fields you fill in once and they ride along on every download, written into a per‑clip **`<clip>.cine.xml`** sidecar:

- **Client, Job, Production, Director, DP, Operator**
- **Lens, Focal length, T‑stop, ND / Filter**
- **Scene, Take, Notes**

These persist across clips and sessions, so set them at the top of the day and forget them. The sidecar also auto‑fills the camera‑derived values you *shouldn't* have to type: **camera model & serial, resolution, frame rate, shutter angle, exposure, frame count, in/out, recorded/trigger time, download time, and the MD5**. Turn the sidecars off with the **`.xml + .mhl sidecars on download`** switch at the top of the Metadata section.

> **What this does and doesn't catch.** Because the camera's source is volatile RAM read once over the wire, there's no original file to hash on the camera side — so this isn't a literal source‑vs‑destination compare. It verifies that what was written to disk is **complete and structurally sound**, and gives you a **travelling checksum** for all downstream copies — which is the protection that matters once the footage is on the laptop.

---

## The monitoring bar

A SmallHD‑style tool strip. Left‑click toggles; right‑click configures. From left to right:

| Pill | What it does | Right‑click options |
|---|---|---|
| **False Color** | Exposure map — colours show exposure levels | Scale (ARRI / Spectrum / EL Zone), Show legend |
| **Peaking** | Focus peaking — highlights in‑focus edges | Sensitivity, edge colour |
| **Zebra** | Diagonal stripes over clipped highlights | Level (luma threshold) |
| **Histogram** | Luma distribution | Scope placement / size / background |
| **Waveform** | Luma across the frame (exposure) | Scope placement / size / background |
| **Vectorscope** | Hue & saturation | Scope placement / size / background |
| **Grid** | Composition grid | Divisions, crosshair, colour, opacity |
| **Guides** | Aspect‑ratio frame guides | Add/scale/position/colour guides (editor) |
| **Video Out** | Opens the external‑monitor window | — |
| **Invert** | Invert the image | — |
| **Flip H / Flip V** | Mirror horizontally / vertically | — |
| **Flicker** | Highlight flickering areas + detect frequency | Overlay sensitivity |
| **LUT** | Load a 3D LUT (.cube) | Load / clear |

The bar scrolls horizontally if the window is narrow, so no tool is ever cut off.

---

## False Color (exposure assist)

False Color paints the image by exposure level so you can judge exposure by **numeric value**, not by how the picture looks. Right‑click the pill to pick a **Scale**:

- **ARRI** — the industry‑standard scale. Red = clipping, orange = hot, yellow = near clip, **pink = skin tones**, **green = 18 % grey**, blue = shadow, purple = crushed blacks.
- **Spectrum** — a smooth pink → blue → green → yellow → red gradient across the exposure range. Good for seeing gradients and roll‑off.
- **EL Zone** — a stop‑based scale: **black = underexposed**, grey = middle grey, **white = overexposed**, with coloured zones for each stop in between.

**Show legend** overlays a labelled band chart along the top so anyone can read the colours. The legend updates to match the active scale.

> Expose skin to the **pink** band (ARRI) or middle of the range, put your grey card on **green** (18 %), and keep important highlights out of **red**.

---

## Scopes

Three real‑time scopes, all sharing one layout panel (right‑click any scope pill):

- **Histogram** — luma distribution; spikes on the right = highlights, left = shadows.
- **Waveform** — luma plotted across the horizontal position of the frame; the standard tool for even exposure.
- **Vectorscope** — chroma plotted as angle (hue) and distance (saturation); for white balance and colour.

**Scope settings (shared):**

- **Position** — pin the scope cluster to any corner: top‑left, top‑right, bottom‑left, bottom‑right.
- **Size** — scale the scopes from 60 % to 180 %.
- **Background** — **Dark** or **Light**. Switch to **Light** if your monitor is very dark and the scopes are hard to read; the boxes become opaque with a border and the histogram/waveform flip to dark‑on‑white.

All three settings persist across launches. Quick keys: `[` / `]` resize, `\` toggles the background.

---

## Grid & Frame Guides

**Grid** (left‑click to show/hide, right‑click for options):

- **Divisions** — None, 2×2, Thirds (rule of thirds), 4×4, 6×6.
- **Centre crosshair** — independent toggle (combine "None + crosshair" for a crosshair‑only frame).
- **Colour** and **Opacity**.

**Frame Guides** are configurable aspect‑ratio markers (e.g. 2.39:1, 16:9, 1:1, 9:16):

- Left‑click the **Guides** pill to **show/hide** all guides; right‑click to open the **editor**.
- **Add Guide**, then per guide set: ratio (preset or custom), **scale** (shrink inside the frame), **position** (X/Y offset), **colour**, **line opacity**, and **dim outside** (darken everything beyond the guide).
- The scale row shows the **resulting crop resolution in pixels** at the current source frame — handy for planning a punch‑in/reframe.
- Each guide has its own **eye toggle** to hide it without deleting it.
- Guides **auto‑save**, so your day's setup comes back on relaunch.
- The editor opens as a pop‑up; click the **window icon** (top‑right of the editor) to detach it into its own resizable window for a heavy setup session.

---

## Image Overlay (onion‑skin)

Lay a saved reference frame over the live image at reduced opacity to **realign a product to exactly where it was** — the SmallHD‑style image‑overlay/onion‑skin tool.

- **Overlay** button (viewer toolbar): **left‑click** shows/hides the overlay, **right‑click** opens the settings.
- **Grab Screenshot** — saves the current monitor frame as a PNG into a **`Screenshots` folder inside your project folder**.
- **Load** — lists every screen grab in the current project; pick one to overlay. You can also **drag any image file** from Finder onto the main window or the overlay panel — it's copied into the project and loaded.
- **Opacity** slider — set ~50 % for classic onion‑skin.
- **Blink** (0–10) — flashes between the live feed and the reference so misalignment jumps out (1 = slow, 10 = ~2× per second; matches SmallHD's blink).
- **Reveal Folder** / **Clear**, and a **window icon** to detach the panel.

**Workflow:** frame your hero → Grab Screenshot → next setup, Load that grab → nudge opacity / turn Blink up → align the new product to the ghost.

---

## Project Clips & DIT report

Open it from the **Clips & DIT Report…** button in the download panel (rail), **File ▸ Project Clips / DIT Report**, or **⌘B** — a contact‑sheet browser of every downloaded clip in the project:

- A **thumbnail** (poster frame, auto‑rendered on download), the filename, key technical metadata, and a **green seal** when the clip has a checksum.
- **Double‑click** a clip to reveal it in Finder.
- **Export Report** writes a `<Project>_Report.csv` (spreadsheet of every clip + metadata + checksum) and a polished `<Project>_Report.pdf` into the project folder, then reveals them — a proper end‑of‑day **camera report** in the ShotPut Pro style:
  - **Branded header** with project, date, and totals.
  - **Offload / verification summary** — Final Status (✓ Verified, with N/N count), checksum type, the offload time window, and the destination path.
  - **Shoot‑info block** (client/job/production/director/DP/operator/camera) pulled from your metadata.
  - **A card per clip** — clip name, size, MD5 + green **✓ VERIFIED** badge, format (res/fps/shutter), camera & white balance, duration/frames/in‑out/recorded time, lens/focal/T‑stop/ND, scene/take/notes — and a **4‑frame contact strip** (four evenly‑spaced frames across the take) on the right.
  - Alternating row shading, page numbers, and footers.

**Where it saves & when it's done:** the report writes to your **project folder** — `<save folder>/<Project>/<Project>_Report.pdf` and `.csv`, right next to the clips. While it builds (the contact strips render a few frames per clip), the button shows **"Generating…"** with a spinner; when finished it **reveals the PDF in Finder** and a **Reveal** button stays in the window.

**How it's built:** each download drops the clip's data into the project folder (`.cine.xml` metadata + `.md5` checksum + thumbnail). The report **compiles those on demand** — there's no per‑clip editing; you just hit **Export Report** at the end of the day.

Clips downloaded before thumbnails existed get one generated on first open.

### Play a downloaded clip on the Client Monitor (2nd display)

The Phantom can only play clips that are still **on the camera** (in RAM). Once a take is **offloaded** to disk it's gone from the camera, so there's nothing to send out the camera's SDI. The **Client Monitor** fixes that — it decodes a saved `.cine` on the Mac and plays it on a second screen for the client, over your laptop's **HDMI / second display**.

- In **Project Clips**, hover a clip and click the **cyan ▶ TV button** (bottom‑right of the thumbnail). A clean, full‑bleed **Client Monitor** window opens and starts playing the clip on a loop. Drag that window to your second monitor and green‑button it full screen.
- The card the monitor is showing gets a **cyan outline** so you know which clip is live.
- Move the mouse over the Client Monitor for a **transport** (play/pause = Space, step, loop, scrub bar, Close); it auto‑hides after a couple seconds for a clean client view.
- Click another clip's TV button to **switch** the monitor to that clip without reopening the window.

**It closes itself automatically** when the camera takes the screen back — the moment you press **LIVE** or start **RAM playback** (Play on the main deck), the Client Monitor window closes so it never sits over a live or camera‑playback feed. You can also close it from its own **Close** button. (This is separate from **Video Out**, which mirrors the *live/camera* feed — see below.)

## Punch-in focus zoom

Magnify the monitor to check critical focus, on the live image or playback:

- **Click "Punch‑In"** in the toolbar for an instant 2×, click again to reset.
- **Pinch** to zoom anywhere from 1×–8×, **drag** to pan around the frame.
- Press **M** to toggle. The current magnification shows in the top‑right of the picture.

It magnifies the real full‑resolution frame, so at 2×+ you're seeing true 1:1 sensor detail.

## Video Out (external monitor)

Mirrors the processed feed to a second display or HDMI output for the client/DP.

- Open it from the **Video Out** pill or **⌘⇧M**.
- **Double‑click** the window for true full screen.
- **Right‑click** for: **Full Screen**, **Always on Top** (floats above other apps), and **Hide Overlays (clean feed)** / **Show Overlays**.
- "Hide Overlays" gives a **clean client feed** — it hides guides, grid, and the onion‑skin overlay so the client sees just the picture.

---

## Flicker detection

For shooting under mains‑powered lighting at high frame rates.

- Left‑click **Flicker** to highlight areas of the image that are flickering frame‑to‑frame; right‑click for **sensitivity** (Low / Med / High).
- The tool can **detect the flicker frequency** and **suggest a shutter** that cancels it.

---

## LUTs

- **LUT** pill: left‑click to **load** a 3D LUT (`.cube`); right‑click to load or **clear**.
- A loaded LUT is applied to the monitor path so you can preview a look. (False Color overrides the LUT while it's active, since false colour needs the raw exposure values.)

---

## Projects, presets & where files go

- Set a **Save folder**, **Project name**, and **Shot name** in the rail.
- Downloads, proxies, and screen grabs are organised as:

```
<Save folder>/
  └─ <Project name>/
       ├─ <Shot>.<ext>            ← downloaded clips / proxies (auto‑incremented)
       └─ Screenshots/            ← onion‑skin grabs & imported overlays
            └─ grab_YYYYMMDD_HHMMSS.png
```

- **Presets** (viewer toolbar) save and recall your tool/look configuration. Save the current setup, name it, and recall it later — also reachable over HTTP (`/preset/<name>`).

---

## The phone remote

A built‑in web remote for a phone or tablet on the **same Wi‑Fi**.

- Open the **keyboard icon** in the viewer toolbar to see the exact URL (something like `http://<your‑mac‑ip>:8989`).
- Type that URL into the phone's browser.
- Tabs: **LIVE / PLAYBACK / MON / SETUP** — a fixed bar at the bottom in portrait; in landscape it tucks neatly under the video. In **full‑screen**, **swipe left/right on the video** to jump between LIVE ⇆ PLAYBACK ⇆ MON without leaving the image. Big **TRIGGER**, a scrubber, mark in/out, save, go‑to‑frame, custom frame rate/shutter, black reference, white balance, clear RAM, and a **live video preview** (JPEG/MJPEG) on the LIVE, PLAY and MON tabs.
- The **MON** tab mirrors the desktop monitoring bar: tap to toggle **False Color** (+ Scale cycle: ARRI/Spectrum/EL Zone), **Peaking, Zebra, Histogram, Waveform, Vectorscope, Flicker, Grid, Guides, Invert, Flip H/V**. Each lights up when active and drives the desktop SDI monitor live, so you can dial in the monitor from across the set with the preview right there.
- The phone preview **mirrors the desktop monitor**, not the raw SDI — the onion‑skin overlay, frame guides and grid are baked into the feed (so you see your reference/guides on the phone, same as the external Video Out).
- **PLAY tab** leads with playback: a **timeline** shows the clip with the **in/out region highlighted** (green band between the yellow In/Out markers) and a draggable playhead — drag to scrub, and you can always see exactly what's marked. Flicker tools are tucked into a collapsed section at the bottom. In **full‑screen PLAY**, that in/out timeline pins across the top of the image, with Play / In / Out / Save in the side menu.
- The MON tab also has full **Image Overlay**, **Grid** and **Frame Guides** control:
  - **Image Overlay** — **Grab Screenshot** from the phone, then browse a **gallery of the project's screen grabs** (served from the Mac) and tap one to load it as the onion‑skin. Adjust **Opacity** and **Blink** with sliders, toggle **Show Overlay**, or **Clear**. So you can capture and recall reference frames entirely from the phone.
  - **Grid** — pick divisions (None / 2×2 / Thirds / 4×4 / 6×6), toggle the crosshair, set opacity.
  - **Frame Guides** — tap an aspect ratio to **add a guide** (2.39, 1.85, 16:9, 4:3, 1:1, 9:16, …); each guide in the list has an eye toggle, a **scale** slider, and a remove (✕).
  - **Image Overlay sits right under the video feed** (the most‑used tool), and every category is a **collapsible section** — tap a heading to fold it away and save screen space.
- **Rotates and rescales** automatically — works in portrait or landscape, and adapts to larger screens (it widens the layout and shows more columns on an **iPad**).
- **Multiple devices at once** — the remote is fully multi‑client, so several phones and iPads can connect to the same Mac simultaneously (e.g. director, DP, and DIT each on their own screen). They all stay in sync, since every device drives the same camera/monitor state.
- **Full‑screen video** — tap the **⛶** button on any preview to fill the screen with the feed (great in landscape / on an iPad). A floating **side menu** appears with the controls for that tab, so you never leave the image:
  - **LIVE** → a big **TRIGGER** + **Go Live**.
  - **PLAY** → **Play/Pause**, **Mark In**, **Mark Out**, **Save**; plus a **‹ / ›** on either side of the top scrub bar to step to the **previous / next cine** without leaving full‑screen.
  - **MON** → **Overlay** on/off, **Grab & Set**, and an **opacity slider**.
  - **Overlay** toggles the onion‑skin on/off — the prop‑continuity workflow: lock a reference, then flip on/off to align a cup/plate/prop back to exactly where it was.
  - **Grab & Set** captures the current frame *and* immediately makes it the overlay reference in one tap — grab the hero before it's touched, then realign to it after.
  - For an edge‑to‑edge view with no browser bars, **Add to Home Screen** in Safari and launch from the icon.
- On an **iPad** (or any wide screen in portrait) the video stays **pinned at the top** while the controls scroll beneath it. **In landscape** (phone or iPad) the layout splits into two columns — the **video locks to the left**, the **controls scroll on the right**, like a monitor with a side panel — and the header shrinks. Portrait stays the simple single column. It all adapts to the screen automatically; nothing to set.
- The PLAY **timeline is styled like the Phantom's**: a cyan **T** marks the trigger (frame 0), a green band shows the marked **in/out** region (what gets saved) between the yellow In/Out markers, and a white playhead you can drag to scrub — so you can read the clip at a glance the way you're used to on the camera.

### No Wi‑Fi on set? (field hotspot)

The camera link is **Ethernet**, so the app controls the camera with **no Wi‑Fi at all** — Wi‑Fi is only ever for the **phone/iPad remote**. When there's no network on location, make one. The remote server listens on every network the Mac is on, so it works over a hotspot exactly like normal Wi‑Fi.

- **Best option — an iPhone Personal Hotspot.** Turn it on, then join it on **both** the Mac and the phone/iPad. The camera keeps running on Ethernet, completely untouched. Nothing to set in the app — just open the **keyboard icon** and scan the QR.
- **Or make the Mac itself the hotspot.** Modern macOS removed the old "Create Network," so this is **Internet Sharing**. In the app, open the **keyboard icon ▸ "No Wi‑Fi on set?"** and press **Create hotspot** — it turns Internet Sharing on with one Mac‑password prompt. If your macOS version won't let it flip on automatically, the app jumps you straight to the settings pane to switch it on by hand. Set **Share to: Wi‑Fi**. Use **Turn off** (in the panel or in Settings) when you're done.
  - **By hand:** **System Settings ▸ General ▸ Sharing ▸ Internet Sharing** → turn it on → *Share your connection from* (any source) → *To computers using:* **Wi‑Fi** → **Wi‑Fi Options…** to set a network password.
  - **Name the network:** Internet Sharing uses your **Mac's name** as the Wi‑Fi network name. To make it read *Phantom Control*, rename the Mac in **System Settings ▸ General ▸ About ▸ Name**.
- Once the hotspot is up, tap **Refresh** in the App Connect panel to regenerate the QR for the new address, then scan it. If the network doesn't show on the phone, toggle the phone's Wi‑Fi off and back on.

---

## Stream Deck / HTTP control

Point an Elgato Stream Deck **"Website / Open URL"** action (or any HTTP GET) at the local server:

```
http://127.0.0.1:8989/trigger
http://127.0.0.1:8989/capture
http://127.0.0.1:8989/live
http://127.0.0.1:8989/play
http://127.0.0.1:8989/pause
http://127.0.0.1:8989/proxy
http://127.0.0.1:8989/download
http://127.0.0.1:8989/preset/<name>
```

---

## Keyboard shortcuts

Single keys — no modifier needed. (Plain keys automatically yield to text fields while you're typing in them.)

### Transport / playback
| Key | Action |
|---|---|
| **Space** | Trigger |
| **C** | Capture / store the take |
| **L** | Go Live |
| **P** | Play / Pause |
| **⇧P** | Play the whole clip from the hero frame |
| **← / →** | Step one frame back / forward |
| **I** | Mark In |
| **O** | Mark Out |
| **⌘1 … ⌘9** | Select Cine 1 … 9 in RAM |

### Monitoring tools
| Key | Action |
|---|---|
| **F** | False Color on/off |
| **⇧F** | Cycle False Color scale (ARRI → Spectrum → EL Zone) |
| **E** | Peaking (focus assist) |
| **Z** | Zebra |
| **H** | Histogram |
| **W** | Waveform |
| **V** | Vectorscope |
| **G** | Grid |
| **A** | Guides show/hide |
| **K** | Flicker |
| **N** | Invert |
| **X** | Flip Horizontal |
| **Y** | Flip Vertical |
| **B** | Overlay (onion‑skin) show/hide |
| **[** / **]** | Scopes smaller / larger |
| **\\** | Scope background Dark/Light |

### Windows / files
| Key | Action |
|---|---|
| **M** | Punch-in focus zoom (toggle 2×; pinch/drag to adjust) |
| **⌘O** | Open a `.cine` file in a player window |
| **⌘⇧M** | Open the Video Output window |
| **⌘B** | Open the Project Clips browser / DIT report |

A condensed version of this list is in the app: click the **keyboard icon** in the viewer toolbar.

---

## Troubleshooting

- **No image / "Not connected."** Check the Ethernet link and that the camera is on the same subnet, then relaunch. The viewer falls back to the Ethernet preview if no SDI device is present.
- **SDI viewer is blank but the camera is connected.** Confirm the capture device appears to macOS and that the app has **Camera/Local Network permission** (System Settings ▸ Privacy & Security).
- **Scopes/histogram hard to see on a dark monitor.** Right‑click a scope ▸ **Background ▸ Light** (or press `\`).
- **A keyboard shortcut "did nothing."** A text field probably had focus — click the image first, then press the key.
- **Won't let me record over a take.** That's overwrite protection — the cine hasn't been downloaded yet. Download it or explicitly clear it.
- **"CineMag ERROR (code N)" or a take won't preview/download.** The CineMag itself is faulting — usually a seating issue. **Reseat the mag** (power the CineStation/camera down first if you can), then refresh the window; the info line should go back to showing the take count. This is the mag reporting a fault, not the app.
- **App won't launch after an update / "code signature" error.** Rebuild once with `./build_app.sh` (it serialises the signing step to avoid corruption).

---

## Error Codes

When a connection fails, the status line shows an **errno** number. These are the network errors macOS reports, in plain English — with what to actually do on set.

### Network errors (errno)

| # | Name | What it means | What to do |
|---|------|---------------|------------|
| **65** | Host unreachable | The Mac has no path to the camera's address — the camera isn't answering. Usual causes: camera still booting, camera busy (it goes silent for 1–2 min during a **CineMag format**), wrong adapter/subnet, or a cable issue. | Wait 30 s and Connect again. Check the cable and that the right adapter is plugged in. If the app still can't connect after the camera is clearly back, quit and reopen the app — the camera's network stack holds dead connections after it's been busy. |
| **64** | Host down | Same family as 65 — the camera looks powered off from here. | Check camera power and the Ethernet link light. |
| **60** | Timed out | The camera exists on the network but stopped answering mid‑conversation — busy, or its Ethernet stack is wedged. | Wait and retry. If it keeps happening, power‑cycle the camera. |
| **61** | Connection refused | The camera answered but wouldn't take the control connection — usually still booting, or too many apps are talking to it. | Wait for boot to finish; close PCC/PVP on other machines. |
| **54** | Connection reset | The camera dropped us mid‑session — it rebooted, or something reset its network. | Just Connect again once it's back. |
| **51** | Network unreachable | The Mac has **no address on the camera's subnet at all** — the adapter isn't configured. | Click the **Set Up Network for …** button under the IP field (asks for your Mac password once). |
| **50** | Network down | The adapter itself is down — USB/Thunderbolt adapter unplugged or asleep. | Reseat the adapter, check the link light. |
| **49** | Address not available | The Mac's address on the camera subnet vanished — usually a reboot cleared the network setup (it doesn't survive restarts). | Run **Set Up Network** again. |
| **32** | Broken pipe | The connection died while a command was in flight. | Reconnect; the app retries most things automatically. |

### Camera replies

- **`ERR: invalid cine number`** — asked for a clip slot that doesn't exist (e.g. a mag take on an empty mag, or a partition number past the end). Refresh the take list / partition strip.
- **`ERR: name … is unknown`** — this camera's firmware doesn't have that setting. Different Phantom generations expose different controls; a control that works on the VEO may not exist on the Flex, and vice versa.
- **Command timeout mid‑session** — the camera is busy (saving to mag, erasing, black ref). Wait for the operation to finish and retry.

### On the camera's own display (OSD)

- **MAG ERROR** — the CineMag didn't seat properly. Unseat it and click it back in; it should come back as **MAG READY**.
- **Erase looks "stuck" at 0 takes** — a format keeps running **inside** the mag for 1–2 minutes after the take counter hits zero. The app shows "blocks left" and only says "CineMag erased" when it's truly done. Don't pull the mag mid‑erase.
- **NO PLAYABLE CINE** — the camera's play menu has nothing to play: RAM and/or mag is empty. Not an error — shoot something.

---

## Glossary

- **Cine** — a stored high‑speed clip in the camera's RAM.
- **Partition** — an independent slice of the RAM buffer; lets you hold several cines at once.
- **Trigger** — the moment you tell the camera to keep the circular buffer.
- **CSR / Black Reference** — current/black calibration the camera runs to clean up sensor noise.
- **False Color / Exposure Assist** — colour‑coded exposure map.
- **Waveform / Vectorscope / Histogram** — exposure and colour scopes.
- **LUT (.cube)** — a 3D colour look‑up table for preview grading.
- **Proxy** — a smaller preview render saved alongside the master.
- **Onion‑skin / Image Overlay** — a ghosted reference frame for re‑aligning shots.
- **OSD** — the camera's own on‑screen display burned into its SDI output.
- **Clean feed** — the picture with all monitoring overlays hidden (for the client monitor).

---

*Phantom Control is an independent tool for Phantom cameras and is not affiliated with Vision Research or SmallHD. "Phantom" and "SmallHD" are trademarks of their respective owners.*
