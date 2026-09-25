# nfc-eink

Flutter/Android app to push text and simple shapes to a **Waveshare 2.9" passive NFC-powered e-Paper**
panel from a Pixel phone.

## Read these first

- **[`docs/PLAN.md`](docs/PLAN.md)** — the plan and the milestone checklists (M0–M6). Tick boxes as
  you go and commit the ticks; that checkbox state is the handoff between sessions.
- **[`PROGRESS.md`](PROGRESS.md)** — current status, environment, hardware baseline, open questions, log.

## Things that will bite you if you don't know them

- **The panel has no battery.** It is powered by the phone's NFC field during the write, so a write is
  a long, fragile, sustained transceive session — not a normal quick tag write. Failures and retries
  are *normal*, not bugs.
- **There is no Android API to control NFC transmit power.** What we can control is how the field is
  used: reader mode with a high `EXTRA_READER_PRESENCE_CHECK_DELAY`, `FLAG_READER_SKIP_NDEF_CHECK`,
  and `setDiscoveryTechnology` on API 35+. Use reader mode, **never** foreground dispatch.
- **Waveshare never published the wire protocol.** It lives in a closed-source, obfuscated `NFC.jar`.
  Phase A uses that JAR via a thin Kotlin shim; Phase B decompiles it and ports to Dart. Do not go
  hunting for public protocol docs — there are none (see the research notes in `docs/PLAN.md`).
- **`android/app/libs/` is gitignored.** `NFC.jar` is Waveshare's SDK and is not committed. Download
  it per the M0 checklist.
- **The Kotlin shim must sit in package `waveshare.feng.nfctag.activity`** — the SDK's main class is
  package-private, and that is the only way to reach it.
- **Nothing NFC can be tested on an emulator, Windows desktop, or web.** A physical Pixel plus the
  panel is required for every write. Only the renderer is testable in isolation
  (`flutter run -d windows`).

## Conventions

- Target exactly one display model: 2.9", 296×128, SDK size code `2`.
- All UI codes against the `EPaperWriter` interface, never a concrete writer — that seam is what
  makes the Phase B port a drop-in swap.
- Render pure black/white only (`0xFF000000` / `0xFFFFFFFF`); no anti-aliased greys.
- Commit at each milestone boundary so sessions have clean resume points.
- `flutter analyze` clean before each commit.
- **Do not make commits.** Nick makes them. Stage nothing and leave the working tree for review.
