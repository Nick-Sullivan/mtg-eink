# Progress

Running state for this project. Keep it short — enough for a session starting cold to resume.
The milestone checklists live in [`docs/PLAN.md`](docs/PLAN.md); tick them there.

## Status

**Current milestone:** M1 — **passed on hardware.** Held 12 s unbroken on the Pixel 10a, UID shown,
removal detected within ~1 s.
**Next:** M2 — download `NFC.jar`, `javap` the obfuscated names, wire the shim, write a bitmap.

**M0 verdict:** misleading, and largely a false alarm — see the vendor-app crash below.
**M1 verdict:** pass. The one finding that made it pass is the presence-check delay; see below.

### The presence-check delay is the whole ballgame

`EXTRA_READER_PRESENCE_CHECK_DELAY` at **5000ms killed the session at exactly 5.0 s, repeatably**.
Not a timeout being exceeded — the platform reaching in on a cadence *we* chose and invalidating the
tag handle (it surfaces as `SecurityException: Tag is out of date`, not an `IOException`). At
**60000ms the hold sails past 10 s.**

The plan called this "the biggest single lever" and suggested ~5000ms. On this hardware 5000ms is
still far too aggressive: it is an interrupt every 5 seconds, not an absence of interrupts. Whatever
M2 does, the delay must exceed the full write duration.

### Build/tooling notes

- The `flutter doctor` Android-licence warning is **cosmetic here** — `flutter build apk --debug`
  succeeds regardless. Don't treat it as a blocker.
- Device is visible to adb as `5C111JEA302773`, `Pixel_10a`, codename `stallion`.

## Environment

| | |
|---|---|
| Flutter | 3.32.8 (stable), Dart 3.8.1 |
| Flutter SDK path | `C:\Users\nickd\Libraries\flutter` |
| Android SDK | `C:\Users\nickd\AppData\Local\Android\sdk`, platform android-36, build-tools 35.0.0 |
| JDK | 21.0.4, bundled with Android Studio (`C:\Program Files\Android\Android Studio\jbr`) |
| Android licences | **NOT accepted** — run `flutter doctor --android-licenses` (blocks Android builds) |
| Test device | Pixel 10a. Connected by USB but **not** visible to `adb` — USB debugging still off |

## Hardware baseline (M0, 2026-09-25)

```
Panel:                Waveshare 2.9" (296x128, SDK size code 2)
Phone:                Pixel 10a
Vendor app write:     FAILED — "update failed please take off the sticker and try again"
                      (there is no sticker; this is the SDK's generic write-failure string)
Panel reaction:       none at all. No flash, no partial refresh.
Tag enumeration:      SUCCESS via NFC Tools. ISO 14443-4.
                      Techs: IsoDep, NfcA, MifareClassic, Ndef
UID:                  D2485852 (4 bytes — not a 7-byte NTAG-style UID)
Attempts needed:      n/a — no successful write yet
Time per full write:  n/a
Best position:        not yet found. Swept the whole back, with a gap; case off,
                      battery charged, battery saver off, screen on.
```

**Read of this:** the chip powers up off the Pixel's field and completes a protocol handshake, so
coupling and silicon are both fine. What fails is the long sustained write. That is the failure mode
the field-discipline settings target, which is why M1 is worth building rather than jumping to the
ST25R3911B escape hatch.

### The vendor app's failure is probably not an NFC failure at all

`adb logcat -b crash` caught Waveshare's own app dying, and it never reached the radio:

```
Process: waveshare.feng.nfctag
java.lang.NullPointerException: Attempt to invoke virtual method
  'android.graphics.Bitmap android.graphics.Bitmap.copy(...)' on a null object reference
    at waveshare.feng.nfctag.activity.MainActivity.X(:198)
    at waveshare.feng.nfctag.utils.AllAngleExpandableButton$g.onTouchEvent(:72)
```

A **null bitmap**, on a button tap, before any transceive. The likely cause is a 2021-era image
picker that doesn't survive modern scoped storage, so the app had no image to send. If that's right,
"update failed" never described a failed write — there was nothing to write, and the panel did
nothing because nothing was sent. **M0 told us almost nothing about NFC power.** Treat the M0 "fail"
as inconclusive rather than as evidence against the Pixel.

Hypothesis, not proof: it's inferred from one obfuscated frame. But it fits every symptom, and M1
passing on the same phone and panel supports it.

**Caveat worth remembering:** `MifareClassic` and `IsoDep` in one tech list is odd — they imply
conflicting SAK values, so NFC Tools may be listing loosely. M1 reports the real ATQA/SAK from
`NfcA`, which will settle it. If the UID turns out to look like an ordinary NTAG sticker rather than
a display driver chip, the vendor app's "take off the sticker" message deserves a second look.

## Open questions

- **The idle removal probe must be off during a write.** `MainActivity.probe()` detects removal by
  close/reconnect, because `isConnected` never touches the tag and we don't yet know a safe
  transceive for this chip. During a transfer that reconnect would be exactly the interruption we're
  avoiding — M2 must suspend it. Once M5 documents the protocol, replace it with a real status read.
- How long does a full 2.9" write actually take? It sets the floor for the presence-check delay.
  60000ms is a guess with headroom, not a measurement.

- Does `nfc_manager` 4.x expose `EXTRA_READER_PRESENCE_CHECK_DELAY`? Unconfirmed. If not, Phase B
  (pure Dart) may not be viable — see the Phase B risk note in `docs/PLAN.md`.
- `NFC.jar`'s obfuscated method names (`a`, `c`) are version-specific. Verify with `javap` in M2
  before writing the Kotlin shim, and record what you find here.

## Log

- **2026-09-25** — M0 run on hardware; see the baseline above. Vendor app fails to write, but the
  panel enumerates cleanly, so the problem is the sustained write, not coupling. Also established
  that **joshuatz's app is not a usable second data point**: there is no prebuilt APK (he side-loads
  his own builds) and the project is 2021-era — `compileSdk`/`targetSdk` 30, `minSdk` 16, and
  `kotlin-android-extensions`, which modern Kotlin has removed. Building it is a toolchain fight with
  no diagnostic payoff, so we skipped it and went straight to M1. Its `NFC.jar` is still the one we
  want in M2, confirmed at `app/libs/waveshare-nfc/NFC.jar` by its `build.gradle`.
  **M1 then passed on hardware the same day.** Two bugs of our own were found and fixed en route:
  (1) `NfcA.isConnected` throws `SecurityException` rather than returning false once the handle is
  stale, which crashed the monitor thread — the loop now treats every throwable as "tag gone";
  (2) a re-discovery left the previous monitor thread polling a dead `Tag`, so discoveries are now
  sequenced with an `AtomicInteger` and stale threads stand down. Then the real finding: the
  presence-check delay. See the section above — it is the single thing that turned failure into a
  pass, and 5000ms (what the plan suggested) is nowhere near enough.
- **2026-09-12** — Project planned and researched. Key finding: Waveshare never published the wire
  protocol; it lives in a closed-source obfuscated `NFC.jar` and no public reimplementation exists.
  Hence the two-phase approach (JAR first, then decompile and port to Dart). Also confirmed there is
  no Android API to control NFC transmit power, which makes the M0 hardware spike load-bearing.
  Repo seeded with `docs/PLAN.md`, `PROGRESS.md`, `CLAUDE.md`.
