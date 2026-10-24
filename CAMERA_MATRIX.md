# Phantom Camera Compatibility Matrix

**Why this file exists (Buddy, 2026-07-09):** every Phantom generation handles
partitions, ISO, log, mags and downloads a little differently. Early features
were built against the VEO4K; later ones against the Flex 2K. This file is the
single place that records **which camera does what, how the app decides, and
what's still an assumption** — so work on one camera never quietly breaks the
other. Update it every time a new per-model difference is discovered.

The fleet this app is developed against:

| | **Phantom Flex 2K** | **Phantom VEO4K PL RLS** | **Phantom CineStation** |
|---|---|---|---|
| Serial / firmware | 10706 · swver 797 | 25593 · swver 30794 | 12607 · Flex-era |
| Network | 100.100.111.76 (GigE only) | 172.16.36.248 (10G) | 1G: 100.100.125.51 · 10G fiber: 172.16.10.251 |

---

## How the app adapts (probed at connect — never by model name)

At connect the app *asks the camera* what it supports (a trial `get` per
feature) and the UI adapts:

| Probe | Flag | Gates |
|---|---|---|
| `get video.adj.log` | `supportsLog` | Look menu → Log 0/1/2 |
| `get video.adj.wbtemp` | `supportsWBTemp` | Kelvin WB submenu **and** which EI mechanism is used |
| `get cam.dark` | `supportsDark` | Close Shutter (BlackShade) button |
| `get cam.quiet` | `supportsQuiet` | Quiet-fan toggle |
| `get cam.cines` | `supportsCinesVar` | Partition verb + record/stop/abort verbs |
| `info.baseei` | `baseEI` | Flex-style gain EI row |
| `info.xinc/yinc/xmax/ymax` | resolution grid | Resolution presets |
| `get mag.size` (polled) | `magPresent` | Auto-save → Mag toggle |

---

## The big differences, feature by feature

### Partitioning RAM
- **Flex:** `alloc {size,size,…}` — slice `cinemem` into equal chunks, then re-arm
  each partition's state. **Erases RAM.**
- **VEO:** `partition N` — one verb, applies instantly, auto-arms everything.
  (`set cam.cines N` answers "Ok!" but silently does nothing — trap.)

> **⚠️ Flex live-view garble on high→low repartition — FIXED & VERIFIED 2026-07-10.**
> Reducing the partition count *while unsaved shots sit in RAM* used to garble the
> live picture (pixelated / heavy chroma noise, sometimes a near-black frame). It's
> purely a *monitor* glitch — the sensor and everything you record are unaffected.
> There were **two causes**, both now fixed:
> 1. **Re-slice timing.** Dropping partitions re-slices camera memory; doing that
>    before the RAM is actually freed mis-aligns the live buffer. The app now clears
>    RAM, **waits 3 s** for the camera to release it, re-slices, then waits 1 s more
>    before re-applying settings. (Repartition erases RAM anyway — nothing extra is
>    lost. The dialog still warns you first.)
> 2. **Stale rolling-cine re-arm.** After a shrink the app was resuming recording on
>    the *old* rolling cine (e.g. c4) — now out of range — which created a phantom
>    active cine and corrupted the feed. It now re-arms only partitions that still
>    exist.
> *Notes:* an *already*-garbled monitor still needs a **power cycle** to clear (soft
> resets don't). The Flex does **not** keep its partition layout across a power cycle
> — re-set partitions after each boot.

> **⚠️ This Flex has no working shutter → black reference needs a LENS CAP.**
> `get cam.dark` is unknown on this body, so there's no internal BlackShade shutter
> to self-close for black — you must **cap the lens** and run Black Ref manually.
> So the app must **never auto-run a black reference** (it doesn't — only your button
> press does). Watch out: **Camera WB (`wbal`) kicks off an internal black reference**,
> so white-balancing without a lens cap gives a bad black cal. After a big config
> change, the correct habit is: cap lens → Black Ref for the new settings.

### Record / stop / abort
- **Flex:** stop-and-keep = `set cN.state {STR}`; abort = `set cN.state {RDY ABL}`.
- **VEO:** both are `rec {cine:0}` — on a triggered cine it stores what's
  recorded so far; on an untriggered one it discards/re-arms.

### ISO / Exposure Index  ⚠️ *completely different mechanisms*
- **Flex 2K:** EI = **video gain**. `video.adj.gain` (1024 = 1×);
  `EI = base EI × gain/1024`. This Flex's base is **1250**, choices are
  doublings (1250 / 2500 / 5000 / 10000 / 20000). The camera's own EI menu
  writes this same field (verified by state-diff). **HQ mode locks EI to
  native** — that's why it "won't go below 2500" when HQ is on.
  No log mode exists on this body.
- **VEO4K:** EI = **named tone curve**. `set video.adj.tone "ExpIndex800"`;
  base EI 320. **Log mode replaces that tone curve → log locks ISO** (matches
  the body's behavior; the app's EI menu now locks itself while Log 1/2 is on).
- In both cases EI is a *develop* setting: **raw files stay raw**, EI rides
  along as metadata + video-path brightness.

### The shared color block (`video.adj`) — who writes what
Several features write into the same camera registers. Know the collisions:

| Field | Written by |
|---|---|
| `red` / `blue` | WB eyedropper, bare `wbal` (Camera WB), Kelvin WB (indirectly) |
| `gain` | Flex EI control (and the Flex body's EI menu) |
| `tone` | VEO EI (ExpIndex curves) **and** Look → tone presets — *they overwrite each other* |
| `log` | Look → Log (VEO only) |
| `wbtemp` | Kelvin WB submenu (VEO only) |

Rules the app now enforces: picking a Look tone preset clears the EI readout
(it really did replace the EI curve); log locks the EI menu; every WB path
re-reads the camera's color so the Match-SDI Ethernet preview stays in step;
Match-SDI now includes the EI gain so the two feeds match at any EI.

### White balance
- **Flex:** bare `wbal` only — the coordinate form `wbal {x,y}` is **rejected**
  on swver 797. The app's click-to-WB samples the raw patch itself and writes
  `video.adj.red/blue` directly.
- **VEO:** also has Kelvin WB (`video.adj.wbtemp`) + color-compensation.

### CineMag / flash
- **Flex + mag:** takes are played with `vplay {cine:<take#>, from:mag}` —
  take numbering is **0-based, no offset** (take 1F = cine 0). Mag takes
  **cannot** be pulled over Ethernet on this firmware — SDI playback only.
  Per-take delete **does not exist** (append-only flash) — only full `ferase`.
  Erase: take-count zeroes instantly, then the mag physically wipes for 1–2 min
  (state 8 → 4); the camera can drop off the network during it (errno 65).
  Save to mag: `fsave {cine, firstframe, lastframe}`, confirm via `mag.takes`.
- **VEO:** takes CFast instead (`cfls`/`cfread` exist; untested with a card).
- **CineStation:** the offload device — mag takes read at 10G via
  `ximg … fmt:flash` (~535 MB/s, verified). Its replies omit the `ssrc` tag the
  cameras include (the receiver auto-locks onto the stream).

### Downloads (RAM cines)
- **Both cameras:** TCP `img` path always works (slow, ~5–40 MB/s).
- **10G path (ximg, ~500 MB/s):** auto-selected when the Mac has a NIC on the
  camera's subnet. Send **no `fmt:`** (native packed-10) — `fmt:P16` truncates.
- **File format note:** fast-path clips currently borrow a VEO4K SETUP template
  (color matrix/levels metadata) with per-clip fields patched — fine in
  practice, but Flex clips carry VEO color calibration metadata (open item).

### Resolution & speed
- **Flex:** width snaps to 256-px steps, max 2560×1600, ~1350 fps max there.
- **VEO4K:** width is **2048 or 4096 only**, height steps of 8, max 4096×2304.

### Video out (SDI)
- Same `video.system` token on both; each camera reports its own supported
  list. No 1080p50/60 on either HD-SDI. PsF/interlaced formats make the
  AVMATRIX capture box bounce — prefer progressive (1080p30 default).

### Sync / genlock
- VEO has no genlock BNC — F-Sync pulse only (`cam.syncimg`). The app's
  Sync section was written for the VEO; the Flex's sync options are unverified.

---

## Known assumptions still in the code (watch list)

Ranked from the 2026-07-09 code audit — none currently bite with this fleet,
but check here first when a new camera model shows up:

1. `supportsWBTemp` doubles as the "VEO-class" switch for the EI mechanism;
   the VEO EI list (250…3200) is hardcoded.
2. `supportsCinesVar` doubles as "VEO-generation record verbs".
3. `hqenable`, `cam.syncimg`, speed-ramp profiles, `video.play.speed/step`,
   OSD/border/detail vars are sent **unprobed** to every camera.
4. Fast-path .cine SETUP template is the VEO4K's (color metadata mismatch on Flex clips).
5. Fallback geometry when `info` omits fields is Flex-shaped (2560×1600/xinc 256);
   fallback CFA is 3 (GBRG) everywhere — older bodies with a different Bayer
   phase would demosaic wrong.
6. Hardcoded identities: CineStation IPs (172.16.10.251 / 100.100.125.51),
   seeded camera IPs, phone-remote subnet filters (100.100.* = Flex link,
   172.16.* = VEO link).
7. Behaviors verified on ONE body each: mag addressing/erase (Flex),
   partial-store (VEO), exp-in-nanoseconds (Flex), ximg no-fmt rule (VEO).
8. `info.features` (`capabilities`) is collected but unused — future gating
   should prefer it where it maps.
9. Mag reader caps at 64 takes; partitions menu offers 1–32 unprobed.

**The golden rule:** when adding a camera-facing feature, probe the capability
at connect (or verify by observation like `deleteMagTake` does), branch on the
probe, and record the discovered difference here.
