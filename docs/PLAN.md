# Flutter app for Waveshare 2.9" passive NFC e-Paper (Android / Pixel)

> **This document is the project plan and the progress tracker.** Tick the boxes as you go and commit
> the ticks — the checkbox state *is* the handoff between sessions. Running notes and hardware
> findings go in [`PROGRESS.md`](../PROGRESS.md).

## Context

`C:\Users\nickd\Documents\Projects\nfc-eink` started as an empty folder. Goal: a simple Android app,
built iteratively in Flutter, that pushes content to a **Waveshare 2.9" passive NFC-powered e-Paper**
module from a Pixel phone. The panel has no battery — it is powered parasitically by the phone's NFC
field while the image transfers, so a write is a long, fragile, sustained transceive session.

v1 scope: **text and simple shapes** (no photo import, no dithering). Minimal rigour: git + lints,
no CI, no test suite. Expected to span several sessions.

**Target is a single model:** 2.9", **296×128**, SDK size code **2**, 4,736 bytes of 1-bit data
(37 bytes/row × 128 rows).

---

## The dominant risk: NFC field power on a Pixel

This is the thing most likely to sink the project, so it is addressed first.

**We cannot control NFC transmit power.** There is no public Android API for RF field strength or
amplitude. It is fixed by the NFC controller firmware and the device's vendor RF configuration
(`libnfc-nci.conf` / NXP RF config blocks in `/vendor/etc`), deliberately locked for regulatory
compliance (FCC/CE/EMVCo). Changing it requires root and a modified vendor config — out of scope.

The concern is real and documented:
- Waveshare's own product pages state the phone "must have enough NFC output power, otherwise it may
  not work," and say the modules are **not compatible with Samsung phones**.
- The author of the main reference app tested on a **Pixel 4a** and found writes "really touch-and-go,"
  often needing several attempts.
- For the 7.5" panel Waveshare recommends abandoning the phone entirely for their ST25R3911B reader board.

Two things work in our favour: the 2.9" is one of the *smaller*, lower-power panels, and Pixels are
reported as working-but-fiddly rather than incompatible.

### What we *can* control — field discipline

Power is fixed, but how the field is *used* is entirely ours, and that is where the wins are:

1. **`EXTRA_READER_PRESENCE_CHECK_DELAY` set high (~5000ms).** The default presence check (~125ms)
   interrupts the transfer repeatedly. Biggest single lever.
2. **`FLAG_READER_SKIP_NDEF_CHECK`** — stops the OS reading NDEF and disrupting the session at connect.
3. **`FLAG_READER_NO_PLATFORM_SOUNDS`** — avoids the system tag-discovery handling path.
4. **`setDiscoveryTechnology(activity, FLAG_READER_NFC_A, FLAG_LISTEN_DISABLE)`** (API 35 / Android 15+,
   with `resetDiscoveryTechnology` on pause). Doesn't add power, but stops the controller cycling
   through other poll technologies and disables card-emulation listen slots, keeping the field
   devoted to NFC-A. Guard with a version check.
5. **Screen on, battery saver off** — Android throttles NFC polling in some power states.
6. **`nfcA.timeout = 1200`** — the SDK default of 700ms is too tight for a slow panel.

### Physical technique (counterintuitive, and it matters)

A **0.25–0.5 inch gap works better than pressing the phone flat against the panel.** This is real NFC
physics, not folklore: at very close range the tag's coil over-couples and detunes the reader's
resonant circuit, degrading power transfer. The app should *tell the user this* during a write. Also
align with the Pixel's antenna, which sits in the **upper-centre of the back**, not the middle.

### Escape hatch

If the Pixel genuinely cannot drive the panel, the fallback is Waveshare's **ST25R3911B NFC reader
board**. That is no longer a phone app, so it would mean rescoping — which is exactly why M0 exists.

---

## M0 — Seed the repo, then prove the hardware

**Write no app code until M0 passes.** If the Pixel cannot drive the 2.9" panel with the vendor's own
software, no amount of Flutter will fix it.

- [x] `git init`; create `docs/PLAN.md` (this file), `PROGRESS.md`, `CLAUDE.md` and `.gitignore`.
      *(Done first — it is what makes the project resumable.)*
- [ ] Commit the seed docs. **Left to you — commits are yours to make, not Claude's.**
- [ ] `flutter doctor --android-licenses` — accept all (currently blocking Android builds).
- [ ] Download `NFC.jar` from the
      [Waveshare Android SDK wiki](https://www.waveshare.com/wiki/Android_SDK_for_NFC-Powered_e-Paper)
      or `app/libs/waveshare-nfc/NFC.jar` in the joshuatz repo. Do **not** commit it (see licensing risk).
- [x] Install **Waveshare's own Android app** (or joshuatz's prebuilt APK) on the Pixel.
      *(Waveshare's. joshuatz has no prebuilt APK — see the 2026-09-25 log entry.)*
- [x] Write an image to the 2.9" panel. Try flush contact *and* a 0.25–0.5 inch gap; hunt for the
      antenna sweet spot; try while charging and at high battery.
      *(Failed — panel did nothing. But it enumerates fine in NFC Tools.)*
- [x] Record in `PROGRESS.md`: did it work, how many attempts, how long a full write takes.

**Gate:** Pass → M1, and you now know the realistic success rate to design the UX around.
Fail → stop and reconsider (different phone, or the ST25R3911B board). Nothing below is worth building.

**Gate result: partial pass, proceeding.** The write failed, but the panel is discoverable and
responds to a handshake, so the field reaches it and the silicon is alive — the failure is in the
sustained write, which is the one part we have levers over. M1 is now the real gate: if the tag
cannot be *held* for 10 s, no amount of field discipline will carry a multi-second image transfer
and the ST25R3911B board becomes the honest answer.

---

## Why the build is in two phases

Waveshare has never published the wire protocol. The transfer command set lives in a closed-source,
obfuscated `NFC.jar` that runs its own `NfcA.transceive()` loop. Research confirms **no public
reimplementation exists**: every known app ([joshuatz](https://github.com/joshuatz/nfc-epaper-writer),
[mk-fg](https://codeberg.org/mk-fg/nfc-epaper-writer), DevPika, lunarcloud) links the JAR, and the one
public request for a non-JAR implementation ([Plugin.NFC #132](https://github.com/franckbour/Plugin.NFC/issues/132))
went unanswered and was closed as not planned. ATC1441 reverse-engineered the *SoC* (Chivotech
TN2115S2) and wrote *replacement* firmware — he bypassed the stock protocol rather than documenting it.

Dart is **not** the blocker: `nfc_manager` 4.x exposes `NfcAAndroid` with `transceive()`,
`getTimeout()` and `getMaxTransceiveLength()`. The missing piece is knowing *which* bytes to send.

**Phase A gets a confirmed working write using the JAR. Phase B decompiles that JAR — with the
working build as a known-good oracle — and ports to pure Dart.**

### Verified JAR API

```kotlin
// Must live in package waveshare.feng.nfctag.activity — the SDK's class `a` is package-private.
val inst = a()
inst.a()                           // init
val ok   = inst.a(nfcA)            // connect; 1 = success
nfcA.timeout = 1200                // override the SDK default of 700ms
val res  = inst.a(2, bitmap)       // size code 2 = 2.9"; 1 = success, 2 = wrong resolution
val pct  = inst.c                  // progress field, poll for UI
```

## Target structure

```
nfc-eink/
  CLAUDE.md                              # points at docs/PLAN.md + PROGRESS.md
  PROGRESS.md                            # cross-session state
  docs/
    PLAN.md                              # this document
    protocol.md                          # Phase B output: the documented command set
  pubspec.yaml
  analysis_options.yaml                  # flutter_lints
  lib/
    main.dart
    models/epaper_display.dart           # 2.9" consts: 296x128, sizeCode 2
    render/canvas_painter.dart           # CustomPainter -> ui.Image -> PNG bytes
    nfc/epaper_writer.dart               # abstract interface (the seam for Phase B)
    nfc/jar_epaper_writer.dart           # Phase A: MethodChannel -> Kotlin -> JAR
    nfc/dart_epaper_writer.dart          # Phase B: nfc_manager, raw transceive
    ui/home_page.dart
  android/app/libs/NFC.jar               # gitignored, download per M0
  android/app/src/main/kotlin/
    com/nickd/nfceink/MainActivity.kt
    waveshare/feng/nfctag/activity/WaveShareHandler.kt   # package-private access shim
```

Scaffold: `flutter create --org com.nickd --project-name nfc_eink --platforms=android .`

### The seam that makes Phase B safe

Define in M2; code all UI against it, so Phase B is a drop-in swap and an A/B test:

```dart
abstract class EPaperWriter {
  Stream<int> get progress;                  // 0-100
  Future<WriteResult> write(Uint8List pngBytes);
}
```

---

# Phase A — working app on the JAR

Each milestone ends in something runnable on the phone. Do not start the next until the current one
is confirmed on hardware. **Commit at each milestone boundary** so sessions have clean resume points.

### M1 — Scaffold + NFC detection

- [x] `flutter create` as above. Add `flutter_lints` to `analysis_options.yaml`.
      *(Package landed as `com.nickd.nfc_eink`, not `nfceink`; gradle is Kotlin DSL, `build.gradle.kts`.)*
- [x] Re-check `.gitignore` after `flutter create` — it may overwrite the one committed in M0.
      The `android/app/libs/` ignore must survive. *(It did.)*
- [x] Manifest: `<uses-permission android:name="android.permission.NFC"/>` and
      `<uses-feature android:name="android.hardware.nfc" android:required="true"/>`.
- [x] `MainActivity.kt` extends `FlutterActivity`. In `onResume`, apply the **full field-discipline
      list from the risk section**: `enableReaderMode` with
      `FLAG_READER_NFC_A or FLAG_READER_SKIP_NDEF_CHECK or FLAG_READER_NO_PLATFORM_SOUNDS`,
      `EXTRA_READER_PRESENCE_CHECK_DELAY` ~5000ms, plus `setDiscoveryTechnology(...)` behind an
      API-35 check. Tear all of it down in `onPause`.
      **Reader mode, not foreground dispatch** — most important reliability decision in the project.
- [x] Hold the discovered `Tag`; push `tagDetected`/`tagLost` to Dart over an `EventChannel`.
      *(Also emits a `held` heartbeat with elapsed ms, and a re-acquire counter — a count that climbs
      while you hold still is the dropout signal we actually care about.)*
- [x] Dart UI: one screen showing "Tag detected: &lt;UID hex&gt;" / "No tag".
      *(Plus held-for seconds, best hold, ATQA/SAK, max transceive length.)*

**Done when:** tapping the panel to the Pixel shows its UID, **and the tag stays present for 10+
seconds without dropping** — that stability is the real thing being tested here.

> **PASSED on hardware, 2026-09-25** (Pixel 10a + 2.9" panel). Held 12 s unbroken, UID shown,
> removal detected within ~1 s.
>
> **The finding that made it pass:** `EXTRA_READER_PRESENCE_CHECK_DELAY` at the 5000ms this plan
> suggested killed the session at *exactly* 5.0 s, every time — the platform invalidating the tag
> handle on a cadence we set, surfacing as `SecurityException: Tag is out of date`. At 60000ms it
> holds fine. **M2 must keep this delay longer than the entire write.**
>
> Two further gotchas, both now handled in `MainActivity.kt` and both relevant to M2:
> - `NfcA.isConnected` only reports a cached flag; it never touches the tag. It cannot detect
>   removal, and it *throws* rather than returning false once the handle is stale.
> - A re-discovery invalidates the previous `Tag`. Any thread still holding the old one must stand
>   down, or it crashes the app — discoveries are sequenced with an `AtomicInteger`.

### M2 — Wire up the JAR, write a hardcoded bitmap

- [ ] `NFC.jar` into `android/app/libs/`; in `android/app/build.gradle`:
      `implementation files('libs/NFC.jar')`. ProGuard keep rule
      `-keep class waveshare.feng.nfctag.** { *; }` so R8 doesn't strip the obfuscated classes in release.
- [ ] **Verify the obfuscated names before writing code:**
      `& "C:\Program Files\Android\Android Studio\jbr\bin\javap.exe" -p -cp NFC.jar waveshare.feng.nfctag.activity.a`
      Adjust the shim if signatures differ from the table above. Record findings in `PROGRESS.md`.
- [ ] Add `WaveShareHandler.kt` in package `waveshare.feng.nfctag.activity` (near-verbatim port of
      joshuatz's shim — it exists solely because `a` is package-private).
- [ ] MethodChannel `nfc_eink/epaper`, method `write(Uint8List pngBytes)`. Kotlin decodes the PNG with
      `BitmapFactory`, converts to `ARGB_8888`, calls `sendBitmap(nfcA, 2, bitmap)` on a
      `Dispatchers.IO` coroutine — `transceive` blocks and must never touch the main thread. Poll
      `handler.progress` every ~50ms onto the EventChannel.
- [ ] Define `EPaperWriter`; implement `JarEPaperWriter` against it.
- [ ] Send a hardcoded checkerboard/`HELLO` PNG from Dart.

**Done when:** tapping the phone to the panel actually changes what it shows.

### M3 — Flutter-rendered text

- [ ] `canvas_painter.dart`: draw into a `PictureRecorder` at exactly 296×128, white background, pure
      black text (`0xFF000000` / `0xFFFFFFFF` only — no anti-aliased greys to fight over), then
      `picture.toImage(296, 128)` → `toByteData(ImageByteFormat.png)`.
- [ ] UI: multi-line text field, font-size slider, live preview at true aspect ratio.

**Done when:** typed text appears on the panel.

### M4 — Simple shapes + robustness polish

- [ ] Small shape palette via the same painter: filled/outlined rectangle, circle, line, border toggle.
      A handful of primitives — this is not a drawing app.
- [ ] States: *waiting for tag → writing N% → done / failed*, and during the write show the physical
      coaching from the risk section — **hold still, leave a small gap, upper-centre of the phone's back.**
- [ ] Map SDK result `2` to "image resolution doesn't match" explicitly.
- [ ] Catch `IOException` and `DeadObjectException` (the NFC radio genuinely dies mid-write on some
      devices); offer one-tap retry without restarting the app — retries are expected to be normal.
- [ ] Keep screen awake during the write (`wakelock_plus` or `FLAG_KEEP_SCREEN_ON`).

**Phase A exit criteria:** a usable app. Everything after is optional refactoring — a good place to
stop if interest or time runs out.

---

# Phase B — port to pure Dart

Only start once Phase A writes reliably. The JAR build stays in the repo as the oracle.

### M5 — Decompile and document the 2.9" protocol

- [ ] Decompile with [jadx](https://github.com/skylot/jadx): `jadx -d out NFC.jar`. The library's whole
      job is assembling byte arrays and calling `transceive` — obfuscation doesn't hide that control
      flow. Read only the `sizeCode == 2` path; ignore the other six models.
- [ ] If ambiguous, use a second oracle: enable Android NFC verbose/NCI logging on the Pixel and
      capture real frames via `adb logcat` during a known-good Phase A write.
- [ ] Write `docs/protocol.md`: init/handshake frames, chunk command format, bytes per chunk, the
      1-bit packing (row-major? MSB-first? is 0 black or white?), the refresh/commit command,
      inter-command delays.

**Done when:** a byte-for-byte description exists that predicts what the JAR sends.

### M6 — `DartEPaperWriter` + A/B

- [ ] Add `nfc_manager` (4.x). Implement `DartEPaperWriter` against the same `EPaperWriter` interface
      via `NfcAAndroid.from(tag)` + `transceive()`, setting timeout through the plugin's API.
- [ ] Pack the 296×128 bitmap to the 4,736-byte 1-bit buffer in Dart per `docs/protocol.md`.
- [ ] Debug toggle to switch implementations at runtime, so the same bitmap can be sent both ways and
      compared on the panel.
- [ ] Once matching: delete the JAR, the shim and the `libs/` entry.

**Done when:** the Dart path matches the JAR path, repeatedly.

### Known risk that may end Phase B early

The field-discipline settings above (especially presence-check delay and `setDiscoveryTechnology`) are
exactly the things a Dart NFC plugin may not expose — and on this hardware they are not optional. If
`nfc_manager` can't set them, options are: keep a minimal Kotlin `enableReaderMode` and do only the
protocol in Dart (still removes the vendor blob), or fork the plugin. **If this blocks, stop and keep
Phase A** — it already works, and pure Dart is a nice-to-have, not the objective.

---

## Other risks

- **Obfuscated JAR:** `a`/`c` names are version-specific. The `javap` check in M2 is the mitigation.
- **Licensing:** `NFC.jar` is Waveshare's SDK, not yours. `android/app/libs/` is gitignored; the
  download step is recorded in M0. (Phase B removes this constraint entirely.)
- **No emulator path:** the NFC layer cannot be tested without phone + panel. The renderer is the only
  part testable in isolation.

## Verification

- `flutter analyze` clean after each milestone.
- `flutter run -d <pixel-id>`; `flutter devices` for the ID.
- Renderer-only iteration without hardware: `flutter run -d windows`, check the preview widget.
- End-to-end: type text, add shapes, tap to the panel, confirm it updates **and holds the image after
  the phone is pulled away** — e-ink is persistent, so the image must survive loss of power.
- Phase B: same bitmap via both writers, visually identical output.

## Reference links

- [joshuatz/nfc-epaper-writer](https://github.com/joshuatz/nfc-epaper-writer) — the reference Android app (MIT)
- [Waveshare passive NFC e-paper writeup](https://joshuatz.com/posts/2021/waveshare-passive-nfc-epaper-modules/)
- [Waveshare Android SDK wiki](https://www.waveshare.com/wiki/Android_SDK_for_NFC-Powered_e-Paper)
- [2.9inch NFC-Powered e-Paper wiki](https://www.waveshare.com/wiki/2.9inch_NFC-Powered_e-Paper)
- [mk-fg/nfc-epaper-writer](https://codeberg.org/mk-fg/nfc-epaper-writer) — fork with dithering
- [atc1441 SoC firmware RE](https://github.com/atc1441/Waveshare_NFC_E-Paper_Display_custom_firmware)
