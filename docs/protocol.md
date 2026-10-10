# Protocol notes

Three different, incompatible protocols exist in this product family. We drive two: the **(G)**
one for the 2.9", and **Rev2.2** for the 4.2" — see the end of this file for the latter.

| | (G) series — **our panel** | original mono/3-colour series |
|---|---|---|
| Transport | `IsoDep` (ISO 14443-4, APDUs) | `NfcA` raw frames |
| Command style | ISO 7816-4, `9000` status words | `0xCD` prefix, `00 00` replies |
| Source | `com.waveshera.epaper` APK, 2025-11-06 | `NFC.jar`, 2021 |
| Obfuscated? | No — plain `IsoDepUtils.java` | Yes — class `a`, methods `a`/`b`/`c` |

Both were recovered by decompiling (jadx for the APK, CFR for the JAR). The panel answers `67 00`
("wrong length", ISO 7816-4) to anything from the old protocol.

---

# The (G) protocol — Waveshare 2.9" NFC-Powered e-Paper (G)

296x128, four colours (black / white / red / yellow). Source: `IsoDepUtils.java` and
`ImageUtils.java` in the vendor APK.

## Transport

`android.nfc.tech.IsoDep`, **`setTimeout(50000)`**. Note how long that is: the app allows 50 seconds
for a single exchange. A full refresh takes ~16 s by Waveshare's own documentation.

## Session

Every session opens by selecting the NDEF application. Note there is **no `Le` byte** — the app
sends exactly these 12 bytes:

```
00 A4 04 00 07 D2 76 00 00 85 01 01      select NDEF application
```

Then unlock and read device info:

```
F0 D8 01 FE 05 00 00 00 00 00            unlock / begin
00 D1 00 00 00                           device info, part 1
F0 D8 00 00 05 00 00 00 00 0E            device info, part 2  -> 6985 means a PIN is set
```

The two info responses are concatenated as hex and parsed into a `DeviceInfo`: width, height,
colour count, colour description, scan direction, compression flag, and **the 2-bit code for each
colour**. So the colour codes are read from the panel, not hardcoded.

### PIN, if `6985`

```
00 20 00 01 <len> <pin bytes>            -> 9000 on success
80 D9 01 02 <len> <oldPin> FF <newPin>   change PIN
```

The app's default attempt is PIN `1122334455`.

## Sending image data

One APDU per 250-byte block, 255 bytes total:

```
F0 D2 <plane> <block> FA <250 data bytes>
        |       |     |
        |       |     +-- 0xFA = 250, the Lc
        |       +-------- block index, 0-based
        +---------------- colour plane index (0 for the 4-colour path)
```

Each must answer `9000`. Data is zero-padded up to `blocks * 250`.

Block count is `ceil((width*height/250) / 4)` for four-colour — **note the integer division**:
`width*height/250` truncates first. For 296x128 that is `37888/250 = 151`, then `ceil(151/4) = 38`
blocks, i.e. 9,500 bytes sent for 9,472 bytes of image.

A compressed path also exists (`CompressUtils.compress`) when the panel reports `isCompress()`.

## Refresh and poll

```
F0 D4 05 <plane|0x80> 00                 start refresh  (F0 D4 05 80 00 for plane 0)
```

| reply | meaning |
|---|---|
| `019000` | done already — do not poll |
| `009000` / `9000` | accepted — now poll |
| `6986` / `68C6` | **busy — not an error.** Resend as `F0 D4 85 80 00` (P1 `0x85`, not `0x05`), up to 5 times, 100 ms apart, then poll |
| `698A` | error |

> **Confirmed on hardware, 2026-09-25.** Our panel answers `6986` to the first `F0 D4 05 80 00`
> *every time*, and the `0x85` retry is accepted. Treating busy as a failure is the single easiest
> way to get a write that transfers all 38 blocks and then falls over at the last step.

Then poll until done, up to 1000 times:

```
F0 DE 00 00 01                           poll refresh state
```

| reply | meaning |
|---|---|
| `009000` | refresh complete |
| `019000` | still refreshing — sleep 100 ms and poll again |
| `698A`, `6986`, `68C6` | error |

## Frame format — established on hardware, not from the app

**This section comes from writing test frames to the panel and photographing the result.** It
disagrees with both the device info and the vendor app, and the panel is the authority.

```
296 rows x 32 bytes = 9,472 bytes
128 pixels per row, 2 bits per pixel, 4 pixels per byte, most significant pair first

byte = p0<<6 | p1<<4 | p2<<2 | p3
```

Held with the long edge vertical, **row 0 is the top** and bit 7 of byte 0 is the top-left pixel.

### Colour codes

| code | colour |
|---|---|
| `00` | black |
| `01` | white |
| `10` | yellow |
| `11` | red |

### Why the panel lies about itself

The device info reports **`colourCount = 2`, 592 x 128, 1 bit per pixel**, describing only black (0)
and white (1). The vendor app believes it and drives this panel down its `writeBlackWhiteScreen`
path. But 592 x 16 bytes is the same 9,472 bytes as 296 x 32, and the panel plainly renders four
colours when you send codes `10` and `11`.

Two mistakes this cost, both worth not repeating:

- Framing the buffer as 592 rows of 16 bytes hides the pixel pairing, and makes a single block
  appear as two blocks in opposite halves of the display.
- Writing only `0x00` and `0xFF` bytes can only ever produce codes `00` and `11`, so the panel looks
  like a black-and-red device. The middle two codes are never sent.

### Scan order

`refreshScan` selects `HorizontalScanning` or `VerticalScanning`. Ours reports 1 (horizontal), and
`HorizontalScanning` is a **no-op** — it strips a 62-byte BMP header and copies rows straight
through. There is no reordering to replicate.

---

# The old protocol — `NFC.jar`, mono and 3-colour panels

**Not applicable to our panel.** Kept because it is the only public description of this command set
we know of, and it is a useful cross-reference.

## Transport

Raw `NfcA.transceive`. The SDK connects and sets a 700 ms timeout internally.

## Size tables

Indexed by SDK size code.

| code | width `d[]` | height `j[]` | rows `e[]` | type byte `h[]` | mode `i[]` |
|---|---|---|---|---|---|
| 1 | 250 | 128 | 122 | 0x04 | 0 |
| 2 | 296 | 128 | 128 | 0x07 | 0 |
| 3 | 400 | 300 | 300 | 0x0A | 0 |
| 4 | 800 | 480 | 480 | 0x0E | 0 |
| 5 | 880 | 528 | 528 | 0x11 | 0 |
| 6 | 264 | 176 | 176 | 0x10 | 0 |
| 7 | 296 | 128 | 128 | 0x08 | 1 |
| 8 | 200 | 200 | 200 | 0x7F | 1 |

## Config read, then handshake

```
30 04 / 30 08 / 30 0C        Ultralight READ, 16 bytes each, failures ignored
```

Command prefix `0xCD`; every step must answer `00 00`.

| command | delay after | meaning |
|---|---|---|
| `CD 0D` | — | hello |
| `CD 00 <h[n]>` | 50 ms | select panel type |
| `CD 01` | 20 ms | setup |
| `CD 02` | 20 ms | setup |
| `CD 03` | 20 ms | setup |
| `CD 05` | 20 ms | setup |
| `CD 06` | 10 ms | setup |

## Packing

Codes 1, 2, 6 and 7 rotate the bitmap **270°** first. Then 1 bit per pixel, MSB first, threshold
`> 128` on the low byte of the ARGB int (the blue channel).

## Return codes from `a(int, Bitmap)`

`1` success, `2` wrong dimensions, `0` a handshake step didn't answer `00 00`, `-1` `IOException`.

## Corrections to the API table in `docs/PLAN.md`

- `a()` is **not** an init call — it is `return this.c`, the progress getter.
- `a(NfcA)` sets the timeout to 700 ms internally, so overrides must come after it.
- Class `a` and its members are `public`; the package shim isn't strictly needed.

---

# The Rev2.2 protocol — Waveshare 4.2" NFC-Powered e-Paper, black and white

400x300, two colours. Source: `waveshare.feng.nfctag.activity.a.r(IsoDep, 3, Bitmap)` in
`NFCTag_EN.apk` (from the 4.2" wiki, `files.waveshare.com/wiki/common/NFCTag_EN.7z`). jadx can't
decompile that method normally; `--show-bad-code` recovers it. **Every step below was then
confirmed on a real panel**, 2026-10-10 — see `PROGRESS.md` for the run log.

The wiki calls this board revision "Rev2.2: the NFC chip has been replaced, and the display is
updated using a fast flashing method". It speaks neither the (G) commands (`6D00` to all of them)
nor the old `0xCD` ones — it isn't NfcA-only.

## Telling it apart

Radio-level, it is identical to the 2.9" (G): techs `IsoDep, NfcA, MifareClassic`, ATQA `0400`,
SAK `28`, maxTransceiveLength 253 (NfcA) / 65279 (IsoDep). **Only the ATS historical bytes differ:**

| panel | ATS historical bytes |
|---|---|
| 2.9" (G) | `90 D2 48 58 52 00` — `90` then the UID |
| 4.2" Rev2.2 | `59 5A 52 43 4F 53 03 00` — ASCII `YZRCOS`, then `03 00` |

The panel doesn't report its size; the vendor app makes you pick it. `YZRCOS` means the 4.2" here
only because that is the only Rev2.2 panel we support.

## What the NFC chip is

A bridge to the display controller (SSD1683-style command set). After authenticating, the phone
pulses the controller's reset line and writes its registers one at a time, as wired firmware would.
Every `74 9x` command answers `9000` whether or not the controller did anything with it — **a
`9000` proves the bridge took the bytes, nothing more.**

## Commands

All over `IsoDep`, CLA `0x74`.

```
74 B1 00 00 08 00 11 22 33 44 55 66 77     authenticate (fixed key)            -> 9000
74 B3 00 00 <n+1> <n> <password>           user password; n=0 sends 01 00      -> 6A00 none set
                                                                                  6A01 accepted
                                                                                  6A02 wrong
74 97 <level> 08 00                        controller reset line, level 01/00  -> 9000
74 99 00 0D 01 <reg>                       select controller register          -> 9000
74 9A 00 0E <len> <data>                   write data to it (also image data)  -> 9000
74 9B 00 0F 01                             read busy: first byte 01 busy, 00 idle, then 9000
```

## Write sequence (400x300)

```
auth; password (only 6A02 stops it)
reset high, 50 ms, low, 50 ms, high, 10 ms
21 <- 48 00          display update control: invert B/W RAM, bypass red RAM — hence 1 = black
3C <- 05             border
1A <- 6E             temperature register — selects the fast waveform
22 <- 91, 20         load that LUT;  wait 100 ms
11 <- 03             data entry: x then y increasing
44 <- 00 31          RAM x window, bytes 0..49
45 <- 00 00 2B 01    RAM y window, rows 0..299
4E <- 00, 4F <- 00 00   address counter to origin;  wait 100 ms
24                   write RAM, then 60 x  74 9A 00 0E FA <250 bytes>  (15,000 = 400x300/8)
22 <- C7, 20         refresh
wait 1000 ms with NO traffic, then poll 74 9B every 250 ms until 00
10 <- 01             deep sleep, mode 1 (keeps RAM) — ours, not the vendor app's; see below
```

The vendor app stops after the busy poll, leaving the controller awake until the panel leaves the
field. Pulled away like that, white areas came up speckled (2026-10-10). Waveshare's wired drivers
for this controller always end with deep sleep, so the app now does too. **It did not cure the
speckle** (tested the same day); it stays because it's what wired firmware does and costs nothing.
The next write's reset pulse wakes it, so nothing else changes.

| phase | measured |
|---|---|
| setup | ~0.8 s |
| 60 data blocks | ~3.2 s |
| refresh (busy) | ~1.6-1.9 s from the `20` |

## Frame format — established on hardware

```
300 rows x 50 bytes = 15,000 bytes, 1 bit per pixel, most significant bit leftmost, 1 = black
```

Held **portrait**, frame row 0 runs down the **left** edge and pixel 0 of each row is at the
**bottom**: the frame is the portrait canvas turned a quarter turn clockwise. Canvas pixel (u, v),
from the top-left, is frame (x = 399 − v, y = u). Found by photographing a probe frame: bars along
row 0 and column 0, a square near the origin, and a thin diagonal that came out smooth (so not
LSB-first, which would sawtooth every 8 pixels).

## The refresh is the fragile part

Every command answers `9000` whether or not the refresh then works; only the busy flag tells.

- **Don't cycle the phone's field.** Turning reader mode off and on, or switching polling off with
  `setDiscoveryTechnology`, left a Pixel 10a's NFC too weak to finish this panel's refresh anywhere,
  until NFC was toggled in settings. Most of the "unreliability" found on 2026-10-10 was this —
  without it, 16 of 16 refreshes ran. Everything below was measured partly under that degradation.

- **A refresh needs more power than the field always gives.** In a weak spot it starts like any
  other, then dies when the panel's stored energy runs out — under 1 s, or once between 1.1 and
  1.6 s — and the picture doesn't change. Good refreshes stay busy 1.6–1.9 s. Which spots are good
  depends on the phone and drifted over a morning on one Pixel 10a.
- **Nothing reports power.** No Android API, no bridge command; the booster power-up (`22 C0`/`20`)
  behaves the same everywhere. The refresh itself is the only test — hence the app's probe: a
  refresh with no image, judged busy at 1.45 s.
- **Retries within a connection never worked**, whatever was varied. A fresh power-up (lift the panel
  away and back) is the only cure seen.
- **Rapid polling cuts a refresh short** (100 ms polls: busy ends at ~0.5 s everywhere). Single polls
  are harmless; the vendor's 1 s of quiet then 250 ms polls is safe.
- **The controller keeps its image RAM across a reset-line pulse**, so a re-refresh needs only reset
  and setup.
