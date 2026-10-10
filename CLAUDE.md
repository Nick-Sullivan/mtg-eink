# mtg-eink

Flutter/Android app to push text and simple shapes to Waveshare passive NFC-powered e-Paper from a
Pixel phone. Two panels: the **2.9" (G)** — 296x128, **four colours: black, white, red, yellow** —
and the **4.2" Rev2.2** — 400x300, black and white. The app tells them apart by their ATS.

## Read these first

- **[`docs/PLAN.md`](docs/PLAN.md)** — the plan and the milestone checklists. Tick boxes as you go
  and commit the ticks; that checkbox state is the handoff between sessions.
- **[`docs/protocol.md`](docs/protocol.md)** — the panel's command set. Everything we know.
- **[`PROGRESS.md`](PROGRESS.md)** — current status, environment, hardware findings, open questions.

## Things that will bite you if you don't know them

- **There are three incompatible protocols in this product family, and we use the two less obvious
  ones.** The 4.2" Rev2.2 has its own (CLA `0x74`, controller register writes); see
  `docs/protocol.md`. What follows is about the 2.9" (G).
  Waveshare's published `NFC.jar`, their Android SDK wiki page, and every third-party project
  (joshuatz, mk-fg, DevPika) target the **monochrome / 3-colour** panels, which use raw `0xCD`
  frames over `NfcA`. **Our (G) panel answers `6700` to all of it.** It is an ISO 14443-4 device
  driven with ISO 7816-4 APDUs over `IsoDep`. Do not follow guidance written for the mono panels;
  it will look authoritative and be wrong.
- **The panel has no battery.** It is powered by the phone's NFC field during the write, so a write
  is a long, fragile, sustained session — a full refresh takes ~16 seconds. Failures and retries are
  *normal*, not bugs.
- **`EXTRA_READER_PRESENCE_CHECK_DELAY` is the dominant reliability lever, and it needs to be huge.**
  At 5000 ms the session died at *exactly* 5.0 s, repeatably — it is the platform invalidating the
  tag handle on a cadence we choose, surfacing as `SecurityException: Tag is out of date`, not an
  `IOException`. It is now 60 s and must always exceed a full write.
- **Never cycle the field: no `disableReaderMode`/`enableReaderMode` toggling and no
  `setDiscoveryTechnology` outside `onResume`/`onPause`.** On 2026-10-10 an automatic "field reset"
  left the Pixel's NFC too weak to refresh the 4.2" anywhere until NFC was switched off and on in
  settings — it looked exactly like a flaky panel, and cost most of a day. Without it, 16/16 writes.
- **There is no Android API to control NFC transmit power.** What we control is how the field is
  used: reader mode with that delay, `FLAG_READER_SKIP_NDEF_CHECK`, and `setDiscoveryTechnology` on
  API 35+. Use reader mode, **never** foreground dispatch.
- **`NfcA.isConnected` never touches the tag.** It returns a cached flag, so it cannot detect
  removal, and it *throws* once the handle is stale. Presence is proved by a close/reconnect probe,
  which must be suspended while a session is open.
- **The renderer must emit exactly four RGB values and nothing else.** The packer matches pixels
  exactly as 24-bit BGR against black `000000`, white `FFFFFF`, red `0000FF`, yellow `00FFFF`. There
  is no thresholding and no nearest-colour fallback — any other value leaves that pixel as whatever
  was already in the buffer. **Anti-aliasing off everywhere.**
- **Nothing NFC can be tested on an emulator, Windows desktop, or web.** A physical Pixel plus the
  panel is required for every write. The renderer and the pixel packing are testable in isolation
  (`flutter run -d windows`, or plain unit tests).

## Where knowledge came from

The vendor app (`com.waveshera.epaper`, from
`files.waveshare.com/wiki/common/WaveShare_NFC.zip`) ships **unobfuscated**. `IsoDepUtils.java` and
`ImageUtils.java`, via [jadx](https://github.com/skylot/jadx), are the source of truth for the
protocol. When something is ambiguous, read them rather than guessing — and prefer what the app
*does* over what looks like it should be required. For example it sends the select and unlock
commands and **never checks their status words**; our panel answers `6A86` to the unlock and the
sequence works anyway.

## Conventions

- **Everything about talking to the panels lives in the `epaper_nfc` package**
  (`packages/epaper_nfc/`, a local Flutter plugin the app depends on by `path:`), kept apart so it
  can be published on its own later. The rule: **the package takes a packed frame and puts it on a
  panel; the app decides what the frame shows.** Rendering, the quantiser, tokens, the design
  library and the UI stay in the app. The package must never import the app.
- **Panel specifics live in `PanelDevice`** (`packages/epaper_nfc/lib/src/panel_device.dart`) —
  geometry, palette, block size, refresh timing. Nothing else hardcodes a dimension or a colour.
  Everything downstream takes a `PanelDevice` parameter, so adding a panel is an entry in
  `PanelDevice.supported` rather than a hunt through the renderer. Two today: the 2.9" (G) and the
  4.2" Rev2.2. Drawing happens on a portrait **canvas**; only the packer maps it onto the
  controller's **frame** (`frame_layout.dart`).
- **Protocol knowledge lives in `gseries_protocol.dart` and `rev22_protocol.dart`** in the
  package's `lib/src/`, chosen by `panel_writer.dart`. They talk through `PanelTransport`, so
  they're pure Dart and tested against a fake panel. Kotlin (`EpaperNfcPlugin.kt`) owns the radio
  and nothing else — it is a dumb `transceive` pipe, because reader mode and the presence-check
  delay can't be set from Dart and `nfc_manager` insists on owning reader mode itself. It follows
  the host activity's resume/pause; the app's `MainActivity` only drives the vibrator.
- Commit at each milestone boundary so sessions have clean resume points.
- `flutter analyze` clean and both suites green before each commit: `flutter test` for the app and
  `flutter test packages/epaper_nfc` for the package — the root run does not include the package.
  Both are pure Dart and run in seconds; there is no excuse for skipping them.
- **The tests exist to protect findings that cost real hardware time.** `quantiser_test.dart` pins
  the chroma weighting (without it every grey sky comes out pink) and the package's
  `frame_packing_test.dart` pins the 2-bits-per-pixel bit layout. Both were established by writing frames to the panel and
  photographing the result; neither fails loudly if broken, they just look wrong.
- **Do not make commits.** Nick makes them. Stage nothing and leave the working tree for review.
