# Progress

Running state for this project. Keep it short — enough for a session starting cold to resume.
The milestone checklists live in [`docs/PLAN.md`](docs/PLAN.md); tick them there.

## Status

**The app works.** 2026-09-25. Compose text in four colours on the phone, hold it to the panel,
and the image appears and stays there. No vendor code in the path: protocol and pixel packing are
pure Dart, Kotlin only owns reader mode and carries bytes.

**Also built:** M6 image import with four-colour dithering, and M7 the saved-design library.

**Next session starts here:** **M8, MTG tokens** — the actual destination. M5 (shapes, retry polish)
is still open but read M8 first: the token layout may decide what shapes are worth building at all.

Two things to be sceptical about before building on them:

- **The ink colours are guesses.** `EPaperDisplay.yellow`/`.red` were eyeballed from a photo, and
  the whole quantiser is calibrated against them — the 9.0 chroma weight is derived from red's
  lightness specifically. Photograph a colour probe and sample the real values.
- **The quantiser has only been judged by eye on a handful of images.** Grey skies going pink is the
  failure mode to watch for; if it happens, raise `_chromaWeight`.

### The panel's own device info

```
>> 00 A4 04 00 07 D2 76 00 00 85 01 01     << 90 00
>> F0 D8 01 FE 05 00 00 00 00 00           << 6A 86     (ignored, as the vendor app does)
>> 00 D1 00 00 00
<< A0 07 F0 07 20 02 50 00 80
   A1 07 01 12 00 30 FF FF FF
   B1 01 1A   B2 01 14   B3 01 00
   C0 09 "waveshare"   C1 04 D2 48 58 52   D1 07 01 20 00 00 00 00 00   90 00
>> F0 D8 00 00 05 00 00 00 00 0E           << "4_color Screen" 90 00
```

Decoded: manufacturer `F0`, **592 x 128**, refreshScan 1 (horizontal), size 1 plane,
**colourCount 2**, black = 0, white = 1, picture capacity 26, user data 20, no battery,
appID "waveshare", UID D2485852, compression off.

**Resolved — the panel lies about itself.** It reports 2 colours, but writing all four 2-bit codes
produces all four colours. The frame is **296 rows x 32 bytes, 2 bits per pixel**, and the codes are
`00` black, `01` white, `10` yellow, `11` red. Full detail in `docs/protocol.md`.

Getting there took three probes and two wrong theories, and the lesson is the same each time:
**photograph the panel rather than describing it.** A photo pulled off the phone with `adb` settled
in one look what several rounds of prose description had left ambiguous.

### Measured timings (2.9" G, Pixel 10a)

| phase | time |
|---|---|
| preamble | ~0.05 s |
| 38 data blocks | **1.6 s** |
| refresh + poll | **21.4 s** |

The refresh dominates, so progress must be weighted by time, not by steps — otherwise the bar races
to 80% and appears to hang.

### The panel sometimes comes up confused

Occasionally the preamble returns a well-formed but nonsense info block — dimensions of 52032,
zeroed capacities, missing appID — and then refuses the first data block with `6A86`. Lifting the
phone away for a few seconds clears it. `readDeviceInfoChecked` now bounds-checks the dimensions and
retries rather than spending 20 seconds discovering the problem at block 0. Root cause unknown.

### Hardware gate

 Waveshare's current app
(`com.waveshera.epaper`, "WaveShare NFC", built 2025-11-06) **writes to the panel from the Pixel
10a**. The panel works, the phone works, and the plan's whole `NFC.jar` premise was simply aimed at
the wrong product.
**Next:** decompile that APK, document its APDU command set, then build our writer against it.

Note this contradicts Waveshare's own documentation, which says in several places that the app
"does NOT support Samsung, Google, and Sony mobile phones", and lists only Xiaomi/Redmi/Huawei/
OnePlus/OPPO/VIVO as tested. On a Pixel 10a it works. Treat that warning as stale, not predictive.

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

## The panel is a Type 4 tag, and the JAR can't talk to it

This is the big finding of 2026-09-25 and it invalidates part of the plan.

`NFC.jar` drives the panel with raw **NfcA** commands prefixed `0xCD` (decompiled — see
`docs/protocol.md`). Our panel does not answer those. Measured with the in-app protocol probe:

| Transport | Result |
|---|---|
| `NfcA.transceive` | every command throws `TagLostException`, including Ultralight `30 04` |
| `IsoDep.transceive` | every command answers `67 00` — ISO 7816-4 for "wrong length" |

`67 00` means the panel is a **smartcard-style ISO 14443-4 device that only accepts APDUs**. Raw
NFC-A frames are invalid once a tag is activated into ISO-DEP, which is exactly why NfcA reports
"tag lost" rather than returning an error.

Confirmed identity:

```
ATS historical:  90 D2 48 58 52 00      (embeds the same D2485852 seen as the UID)
payment (PPSE):  67 00                  — not a bank card
NDEF Type 4:     90 00  ACCEPTED        — it IS an NFC Forum Type 4 tag
IsoDep maxTransceiveLength: 65279       — extended-length ISO-DEP
NfcA  maxTransceiveLength: 253
```

Ruled out along the way: that we were reading some *other* tag in the field (a wallet card).
Moving the panel away reports "tag lost", so the tag under test is definitely the panel.

**Consequence:** Waveshare's own app was never going to work — it isn't a power problem, a phone
problem, or a technique problem. It speaks a protocol this hardware doesn't implement. Every M0
symptom now has an explanation.

**Consequence for the plan:** Phase A as written (drive the panel through `NFC.jar`) cannot work
for this unit. The JAR is still useful as documentation of the *older* protocol, but it is not a
path to a working write here. Phase B stops being an optional tidy-up and becomes the only route.

## It isn't a Waveshare-protocol panel at all

The panel is **red/yellow/black/white — four colours**. Waveshare's NFC e-paper line has seven
types and **none of them is four-colour**; type 7 ("2.9 B") is three-colour and still uses the
`0xCD`-over-NfcA protocol. So this was never the product the plan was written against, whatever the
Amazon AU listing called it.

Identified as **Good Display GDN029F** — 2.9", 128x296, black/white/red/yellow, passive NFC ESL:

- Vendor app is **NFC-D3-Pro**, not Waveshare's NFCTag.
  `https://www.e-paper-display.com/NFC-D3-Pro.apk`, also on Play Store.
- Good Display ship **D-series and G-series** labels with *different apps*. Using the wrong app
  "may cause communication errors". Our unit has no model number printed on it, so if NFC-D3-Pro
  misbehaves, the G-series app is the next thing to try.
- They also mention a PC-side "ImageToNFC" tool and a technical manual — worth chasing, because a
  documented command set would make our app straightforward instead of a reverse-engineering job.
- **Vendor caveat: "Not currently supported on Samsung or Google phones."** A Pixel 10a is a Google
  phone. M1 held a session for 12 s, so the radio side looks fine, but this is on the record.

### What the plan's remaining milestones should become

M2-M6 as written are all premised on `NFC.jar`. For this hardware the shape is:

1. Confirm NFC-D3-Pro can write to the panel from the Pixel. **This is the new M0-style gate** — if
   the vendor's own current app can't drive it, that's the real answer, not a software problem.
2. If it works, decompile *that* APK the way we did `NFC.jar` (CFR worked well) and document the
   APDU command set in `docs/protocol.md`.
3. Then build our writer against that, in Dart or Kotlin. There is no JAR to wrap this time, so the
   Phase A / Phase B split collapses into one phase.

Also note the renderer changes: four colours, not 1bpp black/white. `CLAUDE.md`'s "render pure
black/white only" and the 4,736-byte frame size are both wrong for this panel.

## Device-info format (from `IUtils.loadDeviceInfo` in the vendor APK)

The two info responses are concatenated as hex and parsed as a TLV-ish block:

| offset | meaning |
|---|---|
| byte 0 | `A0` marks a valid info block |
| byte 1 | length; the rest of the parse continues at `bytes[1] + 2` |
| byte 2 | manufacturer code (`80` weixinnuo, `00` jiaxian, `10` yuantai, `20` aoyi, `30` weifeng, `40` PDI, `60` JDF, `70` DKE, `F0` other) |
| byte 4 | colour code: `20` = 2-colour, `30`/`31` = 3-colour, otherwise the count is the high nibble (`40` = 4-colour) |
| hex chars 10-14 | first dimension |
| hex chars 14-18 | second dimension (`124` is special-cased to `122`) |

**Watch the assignment: the app does `setWidth(secondValue)` and `setHeight(firstValue)`** — they
are swapped relative to the order they appear in. Worth verifying against the physical panel rather
than trusting either reading.

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

- **2026-09-26** — Renamed to **mtg-eink** (`com.nicksullivan.mtg_eink`, installs as a new app; logcat
  tag `mtgeink`), new adaptive launcher icon, and an MTG token tab (see M8 in the plan).

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
