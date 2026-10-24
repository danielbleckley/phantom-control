# Phantom `ximg` 10G raw-transfer protocol (reverse-engineered 2026-06-12)

Verified end-to-end against the VEO4K PL RLS (172.16.36.248, 10Gbase-T via OWC
TB Pro Dock en11, MAC `00:23:a4:07:01:0e`): **495 MB/s sustained to disk**
(250 frames, 2.95 GB in 6.0 s) with pixel-exact decode (r = 1.0000, ±0.35 LSB
companding round-trip vs the TCP `img` path, which runs ~6 MB/s).

Implemented in `Sources/PhantomCore/XimgReceiver.swift` (BPF receiver) and
`CameraConnection.downloadCineXimg` / `downloadCine` fast path. CLI:
`phantomctl ximg-download <cine> <out.cine> <first> <last> [--throttle N]
[--batch N] [--iface enX]` and `phantomctl ximg-nic`.

## Sending the command
On the normal control connection (TCP 7115):
```
ximg {cine:<N>, start:<frame>, cnt:<count>, throttle:<T>, dest:<12-hex-MAC-no-colons>}
```
- `dest` = receiving NIC's MAC, lowercase hex, no separators.
- **Send NO `fmt:` field** — you then get the cine's native 10-bit packed
  stream (reply `fmt:266`), complete and smallest. See "fmt trap" below.
- `throttle:<1-99>` (optional) = camera-side pacing, percent of 10G line rate,
  ~11.5 MB/s per percent (measured: 10→115 MB/s, 25→289, 50→572, ≥75→~640
  saturated). Omit or 100 = full blast. Seance defaults to 25%.
- Reply: `Ok! { cine:1, res:4096 x 2304, fmt:266, ssrc:<N> }`
  - `ssrc` increments per ximg command — match it against the stream.
  - The camera then blasts raw L2 ethernet frames at `dest`. No TCP, no IP.
  - Unknown fields in the command are rejected (`ERR: missing argvalue`),
    so only use fields listed here.

### The `fmt` trap (VEO4K firmware quirk)
Reply `fmt` low byte = bits/pixel of the stream (266=0x10A→10bpp packed,
524=0x20C→12bpp packed "P12L", 272=0x110→nominally 16bpp).
- no fmt → 10-bit packed, **complete** (f12=180 blocks) ✓ use this
- `fmt:P12L` → 12-bit packed, complete (f12=216 blocks) — 20% more bytes
- `fmt:P16` → **BROKEN**: camera sends 12-bit packed data but truncates the
  burst at the 10-bit byte budget — you get 5/6 of a frame that misdecodes
  as noise if you treat it as 10-bit. (This wasted half a debugging day.)

## On-wire frame format
- **EtherType `0x88B7`** (IEEE 802a OUI Extended). Filter: `ether proto 0x88b7`.
- Each packet 1504 bytes on wire = 14 ethernet header + 16 ximg header +
  **2 zero pad bytes** + 1472 pixel bytes. (The pads are constant 0x0000 —
  pixel data starts at wire offset 32, NOT 30. Last packet of a burst is short.)

### 16-byte ximg header (big-endian)
| offset | size | field | notes |
|--------|------|-------|-------|
| 0 | u16 | flags | `0x4080` = first packet of a frame; `0x4000` = continuation |
| 2 | u16 | seq | +1 per packet; **resets to 512 (0x200) at every burst** |
| 4 | u32 | f4 | irregular increase (timestamp/CRC-ish); not needed |
| 8 | u32 | ssrc | matches `ssrc` in the control reply |
| 12 | u32 | f12 | burst length in 64 KB blocks (180 = 10bpp 4K frame) |

### Frame reassembly (verified)
- New frame starts at each `flags & 0x0080` packet; concatenate the 1472-byte
  data fields in `seq` order until the next start flag.
- 8014 packets per 4K 10-bit frame = 11,796,480 bytes = exactly
  `width*height*10/8`. No leading header, no trailing padding in the payload.
- Pixel payload (no-fmt request) = **BI_PACKED 10-bit** (4 px in 5 bytes, MSB
  first, top-down, Rec.709-companded — same encoding as packed .cine files).
  Write verbatim via `CineWriter(layout: .packed10)`; CineReader's `unpack10`
  + `cineLinLUT` decodes it (validated pixel-exact against TCP P16).

## Receiver implementation notes
- `/dev/bpf*` works WITHOUT root here (Wireshark's ChmodBPF → group staff/rw).
  BIOCSBLEN 4 MB (set BEFORE BIOCSETIF), BIOCSETIF en11, BIOCIMMEDIATE 1,
  BPF filter ethertype 0x88B7 + dst MAC. Reads return multiple packets with
  `bpf_hdr` framing (bh_hdrlen/bh_caplen, BPF_WORDALIGN=4 between).
- Swift: the BIOC* ioctl macros are unavailable (struct-typed `_IOW`); compute
  them manually — values verified live: BIOCSBLEN=0xc0044266,
  BIOCSETIF=0x8020426c, BIOCIMMEDIATE=0x80044270, BIOCSETF=0x80104267.
- Hot loop is allocation-free; at full blast even tcpdump drops packets
  (caught 5504/8014), so keep the consumer tight and the buffer big.
- Packet loss: gaps in `seq` → mark the frame bad, re-request just that frame
  (`cnt:1`) at a reduced `throttle` (25% then halving). cnt:1 re-requests are
  cheap (~25 ms each).
- 10G NIC autodetect: the `en*` interface whose IPv4 subnet contains the
  camera's data IP (`get eth.xip` = 172.16.36.248 → en11 172.16.36.250/16).

## Camera-side gotchas
- A recording/re-arm (lens cap, CSR, trigger) replaces RAM cine content —
  never compare downloads taken across a re-record. State `WTR/ACT` = no
  stored cine; `img`/TCP refuses ranges but **ximg happily streams garbage**
  for out-of-range frames, so range-check against `firstfr/lastfr` first.
- ximg coexists with the control connection; no data channel (`startdata`)
  needed. Do not trigger/clear mid-download.

## Artifacts
- `ximg.pcap` — early single-frame capture (P16 mode, 12,804 pkts).
- `ximg_speed.pcap` — 20-frame burst (the original 778 MB/s measurement).
- `/tmp` captures from 2026-06-12 protocol debugging are disposable.
