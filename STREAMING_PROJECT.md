# Phantom Stream — low-latency LAN video feed

**Goal:** replace the phone/iPad MJPEG monitor feed with a hardware **H.264 stream over the
local network**, so the wireless monitor is as snappy as a pro wireless video system.
**Scope is LAN-only** (Mac ⇄ iPad/iPhone, same Wi-Fi or a Mac-hosted network) — nothing goes
over the internet, so the entire latency budget is **encode + transport + decode**, all of which
we control. Most shoots are < 20 ft, so RF range is a non-issue.

This is built as a **self-contained module inside Phantom Control** (it reuses the existing SDI
capture session and the HTTP server on :8989), tracked as its own project.

---

## Why MJPEG is the bottleneck (today)

The current feed (`RemoteControl.swift` `/stream`) sends a **full JPEG per frame** (multipart
MJPEG). No interframe compression, a full encode+decode every frame, big payloads. The SDI source
is already correct — swapping the *codec/transport* is the win, not the source.

## Chosen approach: H.264 (VideoToolbox) → WebSocket → WebCodecs

| Stage | Tech | Notes |
|---|---|---|
| Capture | existing `SDICaptureManager` AVCaptureSession | CVPixelBuffer per frame — already have it |
| Encode | **VideoToolbox `VTCompressionSession`**, H.264 | hardware, `RealTime=true`, no B-frames, short GOP, baseline/main; emit SPS/PPS |
| Transport | **WebSocket** on the existing :8989 server | binary frames; SPS/PPS on connect, then NAL units |
| Decode | **WebCodecs `VideoDecoder`** in Safari → `<canvas>` | iOS 17+; lowest in-browser latency |
| Fallback | existing MJPEG `/stream` | if WebCodecs unsupported, auto-fall back |

**Alternative considered — WebRTC:** the gold standard for low latency and the closest to pro
wireless, but a heavy build (signaling, ICE, encoder track). On a controlled LAN, WebCodecs +
WebSocket gives us nearly the same latency with far less machinery and full control of the
pipeline. Keep WebRTC as a Plan B if WebCodecs/iOS support disappoints.

## Now a standalone, reusable module (2026-06-15)

Extracted into its **own SwiftPM target `LANVideoStream`** — zero Phantom dependencies, so any
app can reuse it. Two files: `Sources/LANVideoStream/H264Encoder.swift` +
`Sources/LANVideoStream/VideoStreamServer.swift`. It runs its **own listener + encode threads on
its own port** (Phantom uses 8990 = control port + 1).

```swift
let stream = VideoStreamServer(port: 8990, token: "abc")   // token optional
stream.start()
stream.submit(pixelBuffer, pts: presentationTime)          // from your capture delegate
```

Serves `/<token>/h264` (WS feed) + a minimal turnkey WebCodecs viewer at `/`. Phantom feeds it
SDI frames via `SDIProcessor.onStreamFrame → stream.submit`; its phone page points the WS at
`:8990`. The old WS code was removed from `RemoteControl.swift` (back to plain HTTP/MJPEG).

## Status (2026-06-15)

- **M1 Encoder — DONE.** `Sources/PhantomApp/H264Encoder.swift` (VideoToolbox, RealTime, no
  reorder, 2 s GOP, avcC + `avc1.*` codec string from SPS/PPS, force-keyframe on demand).
- **M2 WebSocket — DONE.** RFC-6455 upgrade + binary fan-out in `RemoteControl.swift` at
  `/<token>/h264` (SHA-1 accept verified locally → `101 Switching Protocols`). Wire protocol:
  byte 0 = type (`0x00` config JSON `{codec,width,height,avcc(base64)}`, `0x01` key, `0x02` delta),
  rest = AVCC NAL data. Encode is gated on `streamClientCount > 0`; a new client forces a keyframe.
- **M3 WebCodecs client — DONE (needs device test).** Per-tab `<canvas>` + `VideoDecoder` in the
  remote page; auto-falls back to MJPEG if WebCodecs is absent OR no H.264 frame arrives in 2.5 s
  (e.g. Mac not on SDI). Wired through `previewStart/Stop`.
- **NEXT: verify on the actual iPad/iPhone (iOS 17+)** — open the remote, confirm the live feed is
  noticeably snappier than MJPEG and falls back cleanly. Then M4 (bitrate knob + latency tuning)
  and M5 (field network).

## Milestones

1. **Encoder** — `PhantomStream/H264Encoder.swift`: VTCompressionSession from the SDI pixel
   buffers; low-latency config; output Annex-B (or length-prefixed AVCC) + SPS/PPS; keyframe on
   demand (new client connect / loss).
2. **WebSocket server** — extend the hand-rolled server (`RemoteControl.swift`) with an RFC-6455
   upgrade + frame (de)framing (server→client doesn't mask). New endpoint e.g. `/h264`. Push
   SPS/PPS to each new client, then encoded frames.
3. **Client decoder** — a page (or an upgrade of the existing remote) that feature-detects
   WebCodecs, configures a `VideoDecoder` from the SPS/PPS, decodes chunks, paints a `<canvas>`.
   Auto-fallback to MJPEG when unsupported.
4. **Tuning + resilience** — bitrate/quality knob (trade sharpness for speed), reconnect, request
   keyframe after a gap, measure end-to-end latency.
5. **Network hosting** — make it work in the field with no infrastructure (see below).

## Mac-hosted network (no LAN available)

True programmatic ad-hoc Wi-Fi is **restricted on modern macOS** (the old "Create Network" menu is
gone; no public hotspot API). Practical options, in order:
- **macOS Internet Sharing** → share to Wi-Fi (needs an upstream link, e.g. the camera Ethernet or
  a USB modem). App can add a one-tap "open Internet Sharing settings" + instructions.
- **Tiny travel router** at the camera — most robust, zero Mac config.
- **iPhone Personal Hotspot** — Mac + iPad both join it.
The HTTP server already binds to **all interfaces**, so whichever network is up, the feed works —
the QR/URL in the app reflects the current IP automatically.

## Open questions / verify

- **iOS Safari version** on Daniel's iPad/iPhone — WebCodecs H.264 decode needs **iOS 17+**. Check
  the actual devices; if older, the MJPEG fallback (or WebRTC) is the path.
- Confirm VideoToolbox encode of the AVMatrix's pixel format (BGRA) — may need a format conversion
  before the encoder.
- Decide URL/UX: a new "fast feed" toggle vs. silent auto-upgrade with MJPEG fallback.

## Definition of done

A noticeably snappier wireless monitor on the iPad over the LAN (target: well under MJPEG's
latency, ideally ~100–200 ms glass-to-glass), graceful fallback to MJPEG on unsupported clients,
and a documented way to host a network in the field.
