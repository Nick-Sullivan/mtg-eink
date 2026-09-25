# mtg-eink

Flutter/Android app to push text and simple shapes to a **Waveshare 2.9" passive NFC-powered
e-Paper (G)** — 296x128, **four colours: black, white, red, yellow** — from a Pixel phone.

## Read these first

- **[`docs/PLAN.md`](docs/PLAN.md)** — the plan and the milestone checklists. Tick boxes as you go
  and commit the ticks; that checkbox state is the handoff between sessions.
- **[`docs/protocol.md`](docs/protocol.md)** — the panel's command set. Everything we know.
- **[`PROGRESS.md`](PROGRESS.md)** — current status, environment, hardware findings, open questions.

## Things that will bite you if you don't know them

- **There are two incompatible protocols in this product family, and ours is the less obvious one.**
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

- **Panel specifics live in `PanelDevice`** (`lib/models/panel_device.dart`) — geometry, palette,
  block size, refresh timing. Nothing else hardcodes a dimension or a colour. Everything downstream
  takes a `PanelDevice` parameter, so adding a second panel is an entry in `PanelDevice.supported`
  rather than a hunt through the renderer. Only one is supported today: the 2.9" (G).
- **Protocol knowledge lives in `lib/nfc/gseries_protocol.dart`.** Kotlin owns the radio and
  nothing else — it is a dumb `transceive` pipe, because reader mode and the presence-check delay
  can't be set from Dart and `nfc_manager` insists on owning reader mode itself.
- Commit at each milestone boundary so sessions have clean resume points.
- `flutter analyze` clean and `flutter test` green before each commit. The suite is pure Dart and
  runs in about a second — there is no excuse for skipping it.
- **The tests exist to protect findings that cost real hardware time.** `quantiser_test.dart` pins
  the chroma weighting (without it every grey sky comes out pink) and `frame_packing_test.dart`
  pins the 2-bits-per-pixel bit layout. Both were established by writing frames to the panel and
  photographing the result; neither fails loudly if broken, they just look wrong.
- **Do not make commits.** Nick makes them. Stage nothing and leave the working tree for review.
