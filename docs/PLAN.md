# Flutter app for Waveshare 2.9" NFC-Powered e-Paper **(G)** (Android / Pixel)

> **This document is the project plan and the progress tracker.** Tick the boxes as you go and commit
> the ticks — the checkbox state *is* the handoff between sessions. Running notes and hardware
> findings go in [`PROGRESS.md`](../PROGRESS.md). The command set is in
> [`protocol.md`](protocol.md).

## Context

A simple Android app, built in Flutter, that pushes content to a **Waveshare 2.9" passive
NFC-powered e-Paper (G)** from a Pixel 10a. The panel has no battery — it is powered parasitically
by the phone's NFC field while the image transfers, so a write is a long, fragile, sustained
session. A full refresh takes **~16 seconds**.

**Target: 296x128, four colours — black, white, red, yellow.** 2 bits per pixel, 9,472 bytes.

v1 scope: **text and simple shapes** (no photo import, no dithering). Minimal rigour: git + lints,
no CI, no test suite.

> ### This plan was rewritten on 2026-09-25, and why matters
>
> The original plan targeted the **monochrome** 2.9" panel and was built around Waveshare's
> `NFC.jar`: a two-phase approach that used the JAR first and ported it to Dart later. That plan was
> well-researched and completely inapplicable. The hardware is the **(G)** four-colour panel, which
> is a different product line with a different chip:
>
> | | planned for | actually have |
> |---|---|---|
> | Colours | black/white, 1bpp, 4,736 bytes | **black/white/red/yellow, 2bpp, 9,472 bytes** |
> | Transport | raw `NfcA` frames | **`IsoDep`, ISO 7816-4 APDUs** |
> | Commands | `0xCD` prefix, `00 00` replies | **`F0 D2` / `F0 D4` / `F0 DE`, `9000` replies** |
> | Vendor code | `NFC.jar`, obfuscated | **APK, not obfuscated** |
>
> The old panel's protocol answers `6700` ("wrong length") on this hardware. Waveshare's published
> `NFC.jar` and the app on the mono wiki page cannot drive this panel at all — which is the real
> reason the original M0 hardware spike appeared to fail.
>
> Because the vendor APK ships unobfuscated, there is no reverse-engineering phase to speak of. The
> Phase A / Phase B split is gone: there is no blob to wrap, so we implement the protocol directly.

---

## What is already established

Don't redo these. Evidence is in [`PROGRESS.md`](../PROGRESS.md).

- [x] The panel works, the Pixel 10a works, and the **correct** vendor app
      (`com.waveshera.epaper`) writes to it. Waveshare's "does NOT support Google phones" warning
      is stale.
- [x] Reader mode with the field-discipline settings holds a session well past 10 s.
- [x] **`EXTRA_READER_PRESENCE_CHECK_DELAY` is the dominant reliability lever**, and the old plan's
      suggested 5000 ms is far too aggressive: the session died at *exactly* 5.0 s, repeatably. Now
      60 s, which must stay longer than a full write.
- [x] The (G) command set is documented in [`protocol.md`](protocol.md).

## Architecture

```
lib/
  models/epaper_display.dart      296x128, the four-colour palette, 9472 bytes
  nfc/apdu.dart                   raw ISO-DEP channel over the MethodChannel
  nfc/gseries_protocol.dart       the command set — all panel knowledge lives here
  render/                         CustomPainter -> ui.Image -> exact four-colour pixels
  ui/home_page.dart
android/app/src/main/kotlin/com/nickd/nfc_eink/MainActivity.kt
```

**Kotlin owns the radio and nothing else.** Reader mode and the presence-check delay cannot be set
from Dart, and on this hardware they are not optional, so `nfc_manager` is not usable — it insists
on owning reader mode itself. Kotlin is therefore a dumb `transceive` pipe; protocol and packing are
pure Dart, which also makes them testable on desktop.

---

### M1 — Scaffold, reader mode, hold the panel ✅ **done**

- [x] `flutter create`; manifest NFC permission and feature.
- [x] Reader mode in `onResume` with `FLAG_READER_NFC_A or FLAG_READER_SKIP_NDEF_CHECK or
      FLAG_READER_NO_PLATFORM_SOUNDS`, a long presence-check delay, and `setDiscoveryTechnology`
      behind an API-35 guard. Torn down in `onPause`.
- [x] `EventChannel` for detected / held / lost, with a re-acquire counter.
- [x] Dart UI showing UID and hold duration.

**Passed:** held 12 s unbroken, removal detected within ~1 s.

### M2 — Read the panel's identity

- [x] Strip out `NFC.jar`, the package shim, the gradle dependency and the ProGuard rule.
- [x] Kotlin `openSession` / `transceive` / `closeSession` over `IsoDep`, serialised on one thread.
- [x] Dart `ApduChannel` and `GSeriesProtocol` with select / unlock / device-info.
- [x] **Read real device info off the panel and record the raw bytes in `PROGRESS.md`.**
- [x] Work out the device-info layout: width, height, colour count, scan direction, compression
      flag, and the 2-bit code for each colour. Cross-check against `IUtils.loadDeviceInfo` in the
      decompiled APK rather than guessing.

**Done.** The panel reports 592x128, 1 plane, **2 colours** (black 0, white 1), horizontal scan,
no compression. Full decode in `PROGRESS.md`.

> Doing this before any write is deliberate. The colour codes are *read from the panel*, not
> hardcoded — pack 9,472 bytes against a guessed layout and a failure is impossible to attribute.

### M3 — Get *anything* onto the panel from our own code ✅ **done**

- [x] Block transfer: `F0 D2 <plane> <block> FA <250 bytes>`, 38 blocks, each expecting `9000`.
- [x] Refresh with `F0 D4 05 80 00`, the `0x85` busy-retry, then poll `F0 DE 00 00 01` to `009000`.
- [x] Progress reporting; the UI shows it, since the whole thing takes ~20 s.
- [x] `render/bit_probe.dart` — a frame built bit-by-bit to test the pixel encoding.

**Passed.** The panel refreshes with our data, no vendor code anywhere in the path.

### M4 — Settle the pixel format, then render properly ✅ **mostly done**

- [x] **Settled by photographing test frames.** 296 rows x 32 bytes, 2 bits per pixel;
      `00` black, `01` white, `10` yellow, `11` red. The panel's own device info is wrong.
- [x] Orientation: row 0 is the top with the long edge vertical; bit 7 of byte 0 is top-left.
- [x] `render/frame_packer.dart` packs a rendered image, snapping each pixel to the nearest of the
      four colours. Nearest-colour, not exact-match: Flutter always anti-aliases text, so demanding
      exact palette values would leave every glyph edge undefined.
- [x] `render/canvas_painter.dart` draws **natively in portrait**, 128 x 296. Nick stands the panel
      on its short edge, so "up" runs along the 296 axis — which is the frame buffer's own
      orientation, so there is no rotation step and no orientation guess to verify.
- [x] Multi-line text, font size, colour pickers, live preview at true aspect ratio.
- [ ] Small shape palette: filled/outlined rectangle, circle, line.
- [ ] The usable width is only 128 px, so long text needs either wrapping guidance or auto-fit.

### M4 — Flutter-rendered text and shapes

- [ ] `render/canvas_painter.dart`: draw at exactly 296x128 into a `PictureRecorder`, then
      `toImage` and read pixels. **Anti-aliasing off everywhere** — the packer matches the four
      palette colours exactly and silently ignores anything else.
- [ ] Multi-line text, font size, colour choice from the four-colour palette, live preview.
- [ ] Small shape palette: filled/outlined rectangle, circle, line, border toggle.

### M5 — Robustness

- [ ] The first `F0 D4 05 80 00` answers `6986` **every time** on this panel and the `0x85` retry
      then works. Worth understanding rather than just tolerating.

- [ ] States: *waiting for panel → writing N% → done / failed*, with the physical coaching during
      a write (hold still, small gap, upper-centre of the phone's back).
- [ ] One-tap retry without restarting. Retries are normal here, not exceptional.
- [ ] Keep the screen awake during a write.
- [ ] Handle the `6985` PIN path, or at least report it clearly.

## Verification

- `flutter analyze` clean after each milestone.
- Renderer-only iteration without hardware: `flutter run -d windows`.
- Packing is pure Dart and can be unit-tested against known bytes without a panel.
- End-to-end: the image must **survive the phone being pulled away** — e-ink is persistent.

## Reference

- [`protocol.md`](protocol.md) — the (G) command set, and the old one for contrast
- Vendor app: `com.waveshera.epaper`, from `files.waveshare.com/wiki/common/WaveShare_NFC.zip`
- [2.9inch NFC-Powered e-Paper (G) product page](https://www.waveshare.com/2.9inch-nfc-powered-e-paper-g.htm)
- Decompile with [jadx](https://github.com/skylot/jadx) — `IsoDepUtils.java`, `ImageUtils.java`
