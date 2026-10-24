# Phantom Control

A native macOS app for controlling **Vision Research Phantom high-speed cameras** over
Ethernet — built by a working filmmaker as a modern, Mac-first alternative to the
Windows-only tooling. Universal binary (Apple Silicon + Intel), macOS 14+.

> ⚠️ **Unofficial.** This project is not affiliated with, endorsed by, or supported by
> Vision Research / AMETEK. *Phantom* is their trademark. The app speaks the camera's
> standard Ethernet control protocol — it never touches firmware.

## What it does

- **Full camera control** — resolution (incl. custom), frame rate, shutter angle,
  ISO/EI (native clean-EI tone-curve ladder + gain push), white balance (Kelvin + spot),
  partitions, black reference, speed ramps, trigger & capture, master reset.
- **Live monitoring** — SDI capture-box viewer with scopes (waveform, vectorscope,
  histogram, false color, zebra, focus peaking), frame guides, LUTs, anamorphic
  desqueeze, flips/vertical mode, punch-in — plus an Ethernet raw preview when no SDI
  box is attached.
- **Image Tools** — live develop panel for the camera's video pipeline (gamma, toe,
  offset, flare, saturation, chroma, hue, R/G/B pedestal), auto-adapting to what each
  body supports.
- **Playback & offload** — RAM-cine deck, CineMag browser with thumbnails, verified
  downloads (MD5 + sidecars + DIT report PDFs), selectable pixel packing (Auto /
  10-bit P10 / 12-bit), 10 GbE `ximg` fast path with TCP fallback, continuous
  record → mag.
- **Timecode** — time-of-day sync, IRIG/SMPTE, time-zone handling.
- **Phone/iPad web remote** — low-latency H.264 feed + controls in any browser on
  the local network.
- **Camera Console** — raw protocol terminal for advanced users.

Also in this package:

| Product | What it is |
|---|---|
| `PhantomApp` | the main app (Phantom Control) |
| `PhantomTranscode` | GPU batch converter: `.cine` → ProRes / H.264 / HEVC |
| `phantomctl` | CLI for protocol probing, downloads, and `.cine` inspection |
| `PhantomCore` | the camera-protocol + `.cine` read/write/debayer library |
| `LANVideoStream` | app-agnostic SDI → H.264 → WebCodecs LAN streamer |

## Cameras it's been used with

Phantom **Flex** (2K), **Flex 4K**, **VEO 4K PL RLS**, and **CineStation IV**.
Per-model protocol differences are documented in [`CAMERA_MATRIX.md`](CAMERA_MATRIX.md);
the 10 GbE raw-Ethernet image protocol in [`XIMG_PROTOCOL.md`](XIMG_PROTOCOL.md).

## Building

```bash
./build_app.sh                 # fast native build → "Phantom Control.app"
UNIVERSAL=1 ./build_app.sh     # Apple Silicon + Intel universal (needs Xcode)
./build_transcode.sh           # Phantom Transcode.app
swift build -c release --product phantomctl
```

Requires macOS 14+ and Swift 5.9+ (Xcode or Command Line Tools; universal builds
need full Xcode).

## Safety

This is beta-quality software used on real jobs — but test everything yourself before
trusting it with paid work. It cannot harm a camera (control commands only, no
firmware), but **data-destructive actions are real**: erasing a CineMag, clearing RAM,
or overwriting files removes footage for good. Those actions always ask first — read
the prompt.

## License

GPL-3.0 — see [LICENSE](LICENSE). © Buddy Bleckley · LA Cinema Robotics.
If you distribute a modified version, you must share your changes under the same terms.
