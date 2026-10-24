# Phantom Control — Release Notes

Newest version on top. The exact build you're running is shown in the app
under **App Connect / Shortcuts** (top-right), e.g. `v0.3.0 (build 12)`.

---

## v0.4.3 — SDI capture that tells you the truth, and an honest 10G readout

Two fixes for problems that were invisible rather than loud. In both cases the
app was quietly doing the wrong thing while reporting success, so nobody could
report a useful bug. Found chasing a report of an UltraStudio that appeared in
the device list but never showed a picture.

**SDI: "connected" and "showing a picture" are now different things.**
The app used to call an SDI feed live as soon as the capture device opened —
which is true even when the device is sending nothing at all. You'd get a green
dot, the words "SDI live", a black screen, and no explanation. Now the status
only goes green when frames actually arrive, and while it's waiting it says so.

**If no picture arrives, the app now goes looking for one.** Some capture
devices (Blackmagic in particular) expose a list of specific input formats
rather than converting whatever they're given. If none of them matches the
signal on the cable — a 50 Hz feed in Europe being the classic case — the
device opens and then sits there silently forever. Phantom Control now waits
three seconds, and if nothing has come through it tries each format the device
offers, showing which one it's on. If it exhausts them it says so plainly,
names the likely cause, and lets the device go.

**The capture card is released properly.** Previously the app grabbed the
capture device at launch and held it until you quit — so Blackmagic Media
Express, Desktop Video Setup, and anything else were locked out of the hardware
the entire time Phantom Control was open. Switching the Viewer to Ethernet now
releases it, and there's a new eject button beside the reconnect button to hand
it back without quitting.

**The download speed readout was lying, and now isn't.** The MB/s figure was
calculated using the 10-gigabit path's data format regardless of which path the
download actually took, so a transfer that had quietly fallen back to the slower
network path was reported about 37% slower than it really was. A genuine
7 MB/s showed up as "5 MB/s". It now measures whatever path is really running.

**New: a 10G status line in the Save panel.** It shows which network interface
is talking to the camera, what speed it negotiated (10 Gbit/s vs 1 Gbit/s), and
whether the fast download path can actually run — with a Re-check button. That
fast path needs two separate things to be true, and until now either could fail
silently and just leave you with a slow download and no idea why. If it can't
run, it now tells you which piece is missing.

**New: a one-click 10G enabler.** This is the piece that has been quietly
costing everyone download speed. The camera's fast path doesn't send normal
network traffic — it fires raw ethernet frames straight at your network card,
below the level ordinary apps are allowed to read. macOS only opens that up to
root, or to a group you explicitly permit. Until now the only way to get it was
to install Wireshark, which nobody knew to do, so downloads silently ran on the
slow path at roughly a tenth of the speed.

Now the 10G status line has a **"Turn On Fast Downloads…"** button. Click it,
enter your Mac password once, and it works immediately — no restart, no logout.
There's a Turn Off button that puts everything back exactly as it was.

It shares the same group Wireshark uses, so if you already have Wireshark the
two cooperate rather than fight. If you'd rather see exactly what's being
changed before running it, **"10G Downloads.zip"** next to the app contains the
same thing as a readable script you can inspect and run yourself.

**Also:** the download zip no longer carries hidden macOS companion files inside
the app bundle — those could make macOS report the app as damaged after
unzipping. Every release is now signature-checked after packaging, so a broken
build can't reach the Latest Version folder.

## v0.5.0 — Open source + Intel support

Phantom Control is now **free and open source** under GPL-3.0:
**https://github.com/danielbleckley/phantom-control**

- **No more beta codes.** The license/serial system is gone entirely — every
  feature (raw downloads, CineMag save, all of it) is unlocked for everyone,
  forever. The welcome popup and the code-entry badge are gone too.
- **Runs on Intel Macs.** The app is now a universal binary — native on both
  Apple Silicon and Intel (macOS 14+). Older Mac Pros and Intel MacBooks in
  rental houses can finally join. Intel output verified byte-identical.
- Source, build instructions, and the per-camera protocol docs are all in the
  repo. Found a bug or want a feature? Issues and pull requests are open.

First launch on a new Mac: the app isn't notarized — right-click the app and
choose **Open** the first time, then it opens normally forever after.

## v0.4.2 — Downloads now carry the camera's real color & exposure metadata

Big correctness fix for how downloaded .cine files look in OTHER apps (Resolve,
PCC, Seance, PhantomFuse). Found by comparing our downloads of the same takes
against Seance downloads (thanks Tim): the RAW image data matched byte-for-byte,
but our file header carried **template placeholder metadata** instead of the
camera's actual state — so metadata-honoring apps rendered our files washed-out,
off-color, and with wrong timecode.

What the header used to say vs. what it now says:
- **White balance** — used to be written as neutral (1.0/1.0); now the camera's
  real WB gains are stamped in, so color comes up correctly.
- **Tone curve** — a leftover EI tone curve from the template was baked into every
  file, lifting the shadows (the "milky" look). Now the file carries the camera's
  actual tone curve — or none at all if none was loaded.
- **Color calibration matrix** — used to be another camera's calibration; now it's
  the shooting camera's own.
- **Trigger timestamp** — was zero (breaking timecode in post); now the real
  trigger time is written.
- **8-bit conversion range** — was tagged 12-bit on 10-bit clips (dark 8-bit
  conversions); now matches the file's true bit depth.

Applies to both regular downloads and camera-side CineMag take downloads. Your
RAW pixels were never affected — this only fixes the metadata other apps read.
Every patched field was byte-verified against reference files from Seance.

If you compared one of our downloads against another app's and they "didn't add
up" — re-download with this build; they should now match.

## v0.4.1 — Choose your download packing + a VEO 4K exposure fix

- **Pick how downloads are packed** (Save tab, next to "Verify downloads"). A new
  **Packing** menu lets you choose how the RAW data is stored in the .cine:
  - **Auto (recommended)** — the fastest *complete* format for your connection (10-bit
    packed over 10 GbE, full 12-bit over 1 GbE). Always the full data.
  - **10-bit packed (P10)** — the camera's native compact format (CineMag / 10G). Smallest
    and fastest; visually lossless and complete for VEO / CineMag footage.
  - **12-bit (16-bit file)** — full uncompressed 12-bit, the most grading latitude on 12-bit
    bodies (e.g. Flex). Larger files, over the 1 GbE path.
  A **?** button next to it explains each in plain English. **None of them reduce quality
  below the camera's native bit depth** — they just trade size and speed. Your choice is
  remembered.
- **Fixed: 10-bit VEO 4K downloads could look too dark in other apps.** Every download's
  header carried a 12-bit "max sample" tag even on 10-bit clips, so a viewer (e.g. Resolve)
  normalized the image against the wrong ceiling and rendered it darker than it should.
  The header now reports the file's true bit depth. Your camera, SDI, and the RAW pixels
  were never affected — only the tag other apps read.

## v0.4.0 — Image Tools, a rebuilt ISO/EI, and Flex 4K support

The big one: a live **Image Tools** develop panel, an ISO/EI control rebuilt to
match how the camera actually behaves, and a batch of Phantom Flex 4K work from
testing on a real body.

**Image Tools — grade the camera live (File ▸ Image Tools, ⇧⌘I).**
A panel of live sliders for the camera's develop pipeline — **gamma, toe, offset,
flare, gamma R/B trim, saturation, chroma, hue, and R/G/B pedestal lift** — each
with a one-click reset (per control, per group, or all at once). It writes
straight to the camera, so changes show on the SDI feed instantly and bake into
your recordings (the raw stays raw). It reads your camera on open and only shows
the controls that body actually has, so it works across the Flex 4K, Flex, and
VEO — and auto-handles the different ways each model stores these values.

**ISO/EI, rebuilt.**
- The EI now changes the **actual camera** on VEO-class bodies (Flex 4K / VEO),
  not just a look. Picking a clean ISO (**250–1250**) loads the camera's own
  calibrated tone curve with gain at unity — no added noise. To go higher, a
  separate **Gain** control unlocks at ISO 1250 and pushes past it (that's where
  the "imaging processing" grain comes in). The number shown is clean-ISO × gain,
  exactly like the body reads it.
- Fixed **ISO 250** not selecting on the Flex 4K.
- The ISO menu only shows the ladder a given camera supports.

**Better Image (Ethernet preview) colour fix.**
On the Flex 4K the "Match SDI" Ethernet preview was mis-graded (gamma flattened,
saturation washed out). It now tracks the SDI feed's grade correctly.

**More camera control.**
- **Camera Console** (File ▸ Camera Console, ⇧⌘K) — a raw command surface for
  advanced users: send any Phantom `get`/`set`, with a reference sidebar.
- **Reset Camera** (Help ▸ Reset Camera) — one click back to a known-good baseline
  (max frame rate, one partition, 180° shutter, cleared RAM, reset white balance),
  with a warning before it wipes.
- **Timecode** (in Sync / Genlock) — sync timecode to time-of-day automatically on
  connect, pick IRIG or SMPTE, and set the camera's **time zone** so the code reads
  right for your location.
- **Continuous → Mag** — with multiple partitions, auto-save each to the CineMag and
  roll straight onto the next, so you can keep recording and triggering nonstop.
- **Anamorphic desqueeze** — an **Ana** button in the monitor tools with common
  desqueeze ratios, plus a **custom resolution** option in the resolution box.

**Flex 4K CineMag.**
Thumbnails and playback for CineMag takes now work on the Flex 4K (it reads flash
frames differently from earlier bodies).

**Fixes.**
- Speed-ramp shutter bug: dropping the frame rate could leave the shutter stuck at
  a tiny angle. The app now clears a leftover ramp so you get your shutter back.
- Look-menu tone presets no longer error on the Flex 4K.

## v0.3.9 — Field hotspot (shoot with no Wi-Fi)

- **"No Wi-Fi on set?" helper** in the App Connect panel (the keyboard icon). With
  no network on location, one tap turns the Mac into a Wi-Fi hotspot so your
  phone/iPad remote can connect. It flips on macOS **Internet Sharing** (one Mac-
  password prompt) and verifies the hotspot actually came up; if your macOS
  version locks that down, it drops you straight into the right settings pane to
  switch it on by hand. **Turn off** right there when you're done.
  - Reminder in the panel: the most bulletproof field option is still an **iPhone
    Personal Hotspot** — join it on both the Mac and the phone.
  - The camera link is Ethernet, so none of this affects camera control.
  - After the hotspot's up, hit **Refresh** for the phone QR at its new address.
- Quick Start guide + in-app Help now cover field networking on current macOS.

## v0.3.8 — Faster on every Mac (esp. Intel / base-M) + hardened binary

Under-the-hood speed pass aimed at machines slower than an M1 Max — nothing
changes about how the app looks or works, it just does the same work with less
strain. Plus a first hardening step for the eventual paid release.

- **Multi-core live preview.** The Ethernet preview develop now runs across all
  your CPU cores instead of one, so the live picture holds a higher frame rate on
  slower/Intel machines. (Verified bit-clean on real camera frames.)
- **Scopes no longer slow the picture.** Turning on the histogram, waveform, or
  vectorscope used to quietly drag the whole live feed onto a slower path. Now a
  scope reads the raw frame and the picture stays on the smooth hardware layer —
  no more jitter just for having a scope up.
- **Scopes scale to resolution.** The scope math now samples a fixed budget, so a
  4K SDI feed costs the same as 1080p instead of ~4× more (identical look).
- **Cached develop tables + lighter fps counter.** The quality-mode tone tables
  are reused between frames instead of rebuilt every frame, and the fps readout
  no longer nudges the whole UI on every single frame. (The Ethernet fps counter
  now reads in whole frames, matching the other readout.)
- **Faster GPU transcode grade** on weak GPUs (Intel iGPU / base-M) — sub-visible
  precision change, meaningfully quicker ProRes/H.264 on those chips.
- **Lighter camera polling** — the storage-capacity check no longer hits the
  camera every second (it's near-constant), freeing the link for the live feed.
- **Hardened binary.** The shipped app no longer exposes its ~16,000 internal
  function names — a first step to make the software harder to reverse-engineer.

## v0.3.7 — Vertical mode, a rebuilt speed ramp, and phone-remote upgrades

- **Vertical camera mode.** Mount the camera on its side for 9:16 and hit
  **Vertical** (toolbar, or the phone's Monitor tab) — the feed rotates upright in
  the viewer, the Video Out monitor, and the phone. Tap cycles off → 90° CW → CCW.
  The rotation is **baked into your proxies/exports and thumbnails**, so
  deliverables come out portrait automatically (the raw `.cine` master stays
  untouched).
- **Speed Ramp, rebuilt around durations.** Each row is a rate held for a
  duration — type frames *or* seconds and the other fills in, and each row's start
  frame auto-fills from the one above. Live graph, presets, and a running total so
  you can gauge the whole shot. *(Still gated: confirmed not to work on the Flex 2K;
  built for VEO / Flex4K.)*
- **Phone remote upgrades:**
  - **Trigger point** control on Live — End / Middle / Start (keep before / 50-50 /
    keep after).
  - **Smart save** — the button reads "Save to CineMag" when a mag's loaded, else
    "Save to Laptop," routed automatically.
  - **Green/gold timeline** — the in/out region and mark handles now actually show
    (they were invisible due to a display bug), matching the desktop.
  - Removed the flicker-detect tools from the phone.

## v0.3.6 — CineMag health, a resizable CineMag window, and clearer errors

- **The app now shows CineMag health.** Both mag windows read the mag's own
  status: **"⚠️ CineMag ERROR (code N) — reseat the mag"** when the mag faults,
  plus **writing… / erasing…** during those operations, otherwise the normal take
  count and space used. If a take won't preview or download, this tells you at a
  glance whether it's the mag (reseat it) rather than leaving you guessing.
- **The CineMag window resizes.** Stretch it taller for more take rows and wider
  to grow the list, just like the CineStation window (it used to be locked to a
  fixed size).
- **The trim preview now names the failure** instead of a generic "couldn't fetch
  preview frame," so a real problem (e.g. a faulted mag) is obvious.

## v0.3.5 — Playback fix, smart Save, EI thirds, and a black-shade reminder

- **Fixed: playing a RAM take right after a CineMag take.** If you played a
  CineMag take and then clicked a RAM partition, it would keep replaying the mag
  take — you had to go Live and back. It now switches straight to the partition
  you click.
- **One-tap "keep this clip."** With a stored RAM clip on the deck, a **Save**
  button now sits right by the in/out frame numbers, and the same option is on the
  right-click menu of the green timeline. It picks the destination for you: **to
  the CineMag** if one's loaded, otherwise **download to the Mac** — so the Flex
  saves to the mag and the VEO downloads, automatically.
- **Full 1/3-stop EI/ISO values.** The exposure-index menu now offers proper
  thirds — 1600, 2000, 2500, 3200 … — instead of only full-stop jumps.
- **Black-reference reminder after a frame-rate change.** Changing the frame rate
  makes the sensor's black shade stale (it's calibrated per rate). A center-screen
  reminder now pops up with a **Run Black Reference** button so you can redo it on
  the spot — cap the lens first. (Cameras with no working shutter can only black-
  reference with the lens capped.)
- **CineMag manager is now its own window.** "Open CineMag" opens a proper window
  with the standard red/yellow/green title-bar controls, matching the CineStation
  window — with a bigger button to open it from the Save tab.

## v0.3.4 — Fixes a partition-change bug that could scramble the live image

The headline is a real bug fix, plus a batch of polish that had been waiting to
ship.

- **Fixed: garbled / pixelated live image after changing partitions.** If you
  reduced the number of partitions while unsaved shots were still in RAM, the
  live monitor could turn to garbage — pixelation, heavy colour noise, sometimes
  a near-black frame. **Your recorded footage was never affected** — this was
  always just the live monitor. The app now clears RAM, waits a few seconds for
  the camera to fully release that memory, *then* re-slices — and it no longer
  tries to resume recording on a partition that no longer exists (that stray
  step was corrupting the feed). *Note for cameras with no working shutter:* an
  already-scrambled monitor still clears with a power cycle, and a black
  reference always needs the lens cap on.
- **TRIGGER is red, CAPTURE is green** — matching the camera so you don't fire
  the wrong one.
- **Permanent download progress bar** in the Save tab — shows percentage, speed,
  and time remaining, and it's always in the same place so nothing jumps around
  when a download starts.
- **Transcodes now match DaVinci.** Exported clips are developed the way DaVinci
  develops Phantom `.cine` files — neutral Rec.709 with a proper highlight
  rolloff and the right colour tags — so what you see in the app matches your
  edit.
- **Clearer download labels** — "Download In→Out to Mac" and "Download ALL stored
  shots to Mac," so it's obvious the footage lands on the computer.
- **Safer CineMag handling** — the app now prevents a Mac download and a
  save-to-CineMag from running at the same time, since that combination could
  jam the camera.
- **First-launch safety notice** reminding you it's beta software and that the
  app only ever *reads* from the camera.

## v0.3.3 — CineMag offload: downloads, thumbnails, ISO, and a CineStation panel

A big one. You can now offload footage from a CineMag — on the camera **or** a
CineStation — with the same full workflow, plus new camera controls.

- **Download takes straight from the camera's CineMag.** Open **Save ▸ CineMag ▸
  Manage…** and every take now has a thumbnail and a download button. Pull one
  take or hit **Download All** — each clip is verified (MD5), gets a proxy `.mov`,
  a metadata sidecar, and a one-page DIT report, and the batch finishes with a
  combined report. No CineStation required for a quick test.
- **CineStation offload window** (File ▸ CineStation, or the big button in the
  Save tab): browse a CineStation's CineMag over 10G with the same treatment —
  thumbnails, verify/proxy/PDF/convert options, Download All, IP entry, and a
  one-click network setup.
- **Thumbnails on every take**, pulled from the *middle* of the clip (where the
  action is), with a Finder-style **size slider**.
- **ISO / EI control** in the Camera tab — set your exposure index like you would
  on the camera body (the app matches how each camera model does it).
- **Auto-save → Mag**: with it on, every trigger saves the shot onto the CineMag
  and re-arms — keep shooting until the mag is full. Right-click to keep or clear
  the RAM copy after each save.
- **Black-reference reminder** (bell icon by Black Ref) — set a minutes interval;
  the Flex 2K's sensor drifts, so it nudges you to re-black-balance.
- **CineMag erase** now shows true progress and only reports done when the flash
  is fully wiped. Per-take delete is honest about append-only mags.
- Nicer touches: **Trigger is red / Capture is green** (matches the camera body),
  connection status is up by the Connect button, and there's an **error-code
  reference** in Help.
- **First-launch safety notice**: Phantom Control only reads status and sends
  standard control commands (same as PCC) — it never touches camera firmware and
  can't harm the camera. The only risk is data loss from erase/clear actions,
  which always confirm first.

---

## v0.3.2 — DIT report thumbnails show the full frame

- **DIT report thumbnails now match what you shot.** The end-of-day report was
  squeezing each clip's frames into a fixed portrait box and cropping off the
  sides, so a widescreen shot only showed its middle slice. Now each thumbnail is
  drawn at the clip's **real captured aspect ratio, full frame — no cropping** —
  so the report shows exactly what was in frame.
- The per-clip contact strip is now **3 larger frames** (start / middle / end)
  instead of 4 tiny ones, so each is actually readable.

---

## v0.3.1 — Ethernet colour accuracy & feed defaults

**Follow-up to the colour work: the Ethernet feed now defaults to the most
accurate picture, carries an honest note about what it is, and its "Match SDI"
mode now uses the camera's real colour recipe.**

- **Ethernet feed now defaults to *Better Image* (12-bit)** so the live network
  preview shows the most accurate colour and detail out of the box. Switch to
  *More FPS* on a slower connection if you want a snappier preview.
- **New Ethernet feed note:** a small notice reminds you the network preview is a
  live *raw* monitor — great for framing and focus, a close colour reference but
  not a calibrated match to the SDI feed, and it can show faint sensor banding.
  Your recordings and downloads are full quality and completely unaffected.
- **"Match SDI" is now grounded in the camera's actual settings.** We captured a
  live SDI session and confirmed exactly how the camera develops its picture
  (per-channel white-balance gains + a 2.2 gamma; no colour matrix or flare on
  this Flex). Match SDI now applies those real values instead of guessing, so the
  colour reads correctly. It's still optional (off by default) and the live feed
  will still show the faint banding noted above.

**Under the hood (for the curious):** we verified our download is *bit-for-bit
identical* to what Phantom's own software (PCC) pulls from the camera — same
pixels, exactly. So the picture data is perfect; the only thing that ever
differed was how the preview is "developed" for display, which is what the above
changes address.

---

## v0.3.0 — Ethernet feed & white balance

**The Ethernet video feed and white-balance workflow.**

Ethernet live feed (for testers without an SDI capture card):
- Feed now has real picture processing (auto black/white levels + contrast) so
  it looks like a picture instead of a flat, milky raw scan.
- **Feed quality switch:** *More FPS* (8-bit, ~8 fps) vs *Better Image* (12-bit,
  ~4 fps, smooth/banding-free — PCC-style). Recordings are always full quality.
- Live frame-rate readout next to the feed picker.
- The feed prioritizes colour accuracy — no artificial saturation boost by default.
- New Black / White / Contrast / Saturation sliders + an "Auto" button to tune
  the look (Ethernet viewer only; never affects recordings).

White balance — now done the correct, camera-accurate way:
- **Black-balance-first reminder:** white balancing without a black reference
  throws colour off, so the app now warns and offers to run Black Reference first.
- White balance now keeps the Ethernet feed and SDI **consistent** — previously
  they were balanced separately, so SDI looked off after a WB.
- Click-to-white-balance eyedropper measures the raw sensor at the clicked spot.
- Camera WB waits for the black reference to finish before balancing.

Also in this build:
- Strictly beta now: no storefront / "buy" anywhere. Your beta code IS the
  14-day trial. Activation is more reliable (persists even on a fresh download),
  and a locked feature now says "enter your beta code" and opens the code panel.
- About Phantom Control shows the author + contact.
- Black-frame noise fix: a near-black frame (e.g. capped lens) no longer gets
  its noise floor amplified by the auto-levels stretch — black stays black.
- About Phantom Control (author + contact) in the menu.
- Version numbers + this release-notes file.
- CineMag media manager (view takes, delete, capacity bar).
- Playback speed-ramp slider (crawl to 5×, drag while playing).
- One-click network setup, including auto-fixing an IP address conflict.
- iPhone/iPad remote works from a stable address (add to Home Screen in Safari).
- Beta licensing: time-limited beta codes.
- Clearer button labels (Focus, Cam Guides, Speed Ramp, App Connect / Shortcuts).

---

<!-- Template for the next entry — copy this above when you cut a new version:

## vX.Y.Z — <short theme>

- change
- change

-->
