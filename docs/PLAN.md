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
no CI. **There is now a fast unit-test suite** (`flutter test`, ~1 s, pure Dart) covering the frame
bit layout, the quantiser's colour invariants and the design store — the parts where a regression
is silent rather than loud.

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
android/app/src/main/kotlin/com/nickd/mtg_eink/MainActivity.kt
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

### M5 — Shapes and robustness

- [ ] The first `F0 D4 05 80 00` answers `6986` **every time** on this panel and the `0x85` retry
      then works. Worth understanding rather than just tolerating.

- [ ] States: *waiting for panel → writing N% → done / failed*, with the physical coaching during
      a write (hold still, small gap, upper-centre of the phone's back).
- [ ] One-tap retry without restarting. Retries are normal here, not exceptional.
- [ ] Keep the screen awake during a write.
- [ ] Handle the `6985` PIN path, or at least report it clearly.

---

# Where this is going

Nick's intentions for later sessions, recorded so a cold start knows the destination. Roughly in
order, but not a commitment to that order.

### M6 — Import an image and approximate it in four colours ✅ **built, not yet judged on hardware**

- [x] Pick an image from the gallery; pan and pinch to frame it in 128 x 296.
- [x] Quantise in Oklab with chroma-weighted matching and a hue gate (`lib/render/quantiser.dart`).
- [x] Atkinson error diffusion, serpentine, with auto-levels for photos.
- [x] Preview shows the **quantised** result, not the source.
- [x] Photo / Graphic toggle — flat nearest-colour is the right answer for logos and line art.
- [ ] **Judge it on real photographs and tune.** Nothing below has been checked against the panel.

> **The trap, and why the code looks the way it does.** The problem isn't the missing green and
> blue — it's **red**. Red sits at Oklab lightness 0.53, almost exactly neutral mid-grey, so *any*
> plain distance metric picks red for a grey pixel and every overcast sky comes out pink. Moving
> from RGB to Oklab does not fix it; in Oklab a mid-grey is ~8x closer to red than to the neutrals.
>
> The fixes, both load-bearing: chroma error weighted 9x lightness error (break-even is 8.1), and a
> hue gate that neutralises anything outside the inks' 31°-90° warm wedge, because no mixture of
> these inks makes a cool hue at any resolution — ungated, that error can never be discharged and
> diffusion smears it into red.

Ideas not built, in rough order of likely value:

- [ ] A **brightness slider**. With four levels, exposure is a creative decision no heuristic wins.
- [ ] A **saturation slider** (0 = monochrome, 1 = faithful, 2 = poster). Subsumes "turn red off".
- [ ] Floyd-Steinberg and Bayer 8x8 as alternative kernels. FS keeps more fine texture; Bayer suits
      flat graphics and is stable while dragging a slider.
- [ ] **Calibrate the ink colours against a photograph of the panel.** `EPaperDisplay.yellow` and
      `.red` are guesses, and the whole quantiser is tuned against them — if the real red is duller,
      its lightness moves and the 9.0 weight needs re-deriving. Same "photograph it" lesson as the
      pixel-format work, and it degrades quality silently rather than failing loudly.

### M7 — A library of saved designs on the phone ✅ **built**

- [x] Save from Text or Image mode, list in a third "Saved" tab with real-ink thumbnails, tap to
      select, Write to send. Rename and delete from a per-row menu.
- [x] JSON index plus one raw `.frame` file per design, under the app documents directory.

**Changed from the original intent, deliberately.** The plan said to store `PanelContent` so designs
stay editable. What's stored is the **packed frame** instead:

- a re-send is byte-identical to the original write, whatever the renderer does later
- 9.5 KB per design — a hundred of them is smaller than one source photo
- it works identically for text and imported images, with no second code path

The cost is that saved designs can be **re-sent but not edited**. That fits "a shelf of finished
labels". If editing is wanted later, add the `PanelContent` JSON alongside the frame for
text-mode saves — the frame stays the source of truth for sending.

- [ ] Reordering, and maybe folders, if the list gets long.
- [ ] Nothing dedupes identical frames.

### M8 — Magic: the Gathering tokens

The actual destination. A token needs: creature name, type line, power/toughness, colour identity,
and ideally art.

- [x] A token template as a first-class layout, not free text: name, type line, P/T box, art area.
      The **MTG** tab (`lib/render/token_painter.dart`, `lib/ui/token_editor.dart`): black frame,
      white title/type bars, hatched art box, P/T box bottom right. Text shrinks to fit, then
      ellipsises. Checked on the phone preview; **not yet written to the panel**.
- [ ] Make P/T legible at a glance — that is what the panel is *for* during a game. The P/T box is
      18px bold today; judge it on the panel from across a table.
- [x] Optional ability text: a wrapped text box between the type line and P/T that only appears
      when there is text, taking its height from the art. Shrinks 11px → 7px, then ellipsises.
- [x] Save tokens to the library. Same `designs/` store; the index entry carries `kind: token` and
      the fields, so opening one lands in the MTG tab, editable. Entries without a kind are images.
- [ ] Batch mode: hold a queue of tokens and write them one per tap, so a set of panels can be
      filled in one sitting.
- [ ] Optional: pull card data from an API such as Scryfall by name. Needs network permission and a
      cache; worth it only if typing them by hand becomes the bottleneck.

> **Aspect ratio is the design constraint.** A real card is 63 x 88 mm (ratio 0.72); this panel is
> 128 x 296 (ratio 0.43) — considerably taller and narrower. A token layout cannot just be a
> shrunken card face. Expect a stacked design: big P/T, name, minimal art.

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
