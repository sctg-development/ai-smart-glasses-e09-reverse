# e09_reverse — BLE Research & Demo Tool for Eyevue-style Smart Glasses

A standalone macOS command-line tool for exploring, validating, and demonstrating the Bluetooth
Low Energy (BLE) protocol used by a family of camera-equipped smart glasses (marketed under names
such as "Eyevue E09" and similar OEM variants) that pair with a companion phone app and offer a
voice-activated "Hi Luma"-style AI assistant.

I did not find any information about theses glasses.
I found a http only website from the manufacturer http://www.taiyang-keji.com/ProDetail.aspx?ProId=161 without any information.

<img width="1972" height="1358" alt="image" src="https://github.com/user-attachments/assets/2fc053ad-b850-460b-bb2c-4c98da30d749" />

## Motivation

Devices like these ship with a voice assistant wired to whatever cloud AI backend the
manufacturer happened to pick, with essentially no visibility for the end user into which
provider actually processes their voice, photos, or conversations, how long that data is kept, or
under what terms. That's an opaque, take-it-or-leave-it black box you can't inspect, audit, or
swap out — and it's the main reason this project exists: to show that the same hardware
capabilities (wake word, live microphone streaming, photo capture, spoken replies) can just as
well be driven by an AI backend **you** choose, with **your own** API key, and full visibility
into every request being made on your behalf. The `validateHiLumaDemo` test demonstrates exactly
that using Mistral AI as one concrete, easy-to-swap-in example — nothing about this project is
tied to any particular AI vendor.

The tool was built by capturing and probing real BLE traffic against physical hardware — no
firmware or companion-app internals are included in this repository. It serves two purposes:

1. **Protocol validation** — a suite of BLE tests that exercise documented and undocumented
   commands against real glasses, to characterize exactly how the hardware behaves.
2. **Capability demonstration** — a small end-to-end voice-assistant demo (wake word → speech
   recognition → intent routing → photo/vision/time → spoken reply) built on top of the same BLE
   layer, showing what these commands can be used for beyond the original companion app.

> ⚠️ **Disclaimer**: This is an independent research project, not affiliated with, endorsed by, or
> supported by the glasses' manufacturer. It is provided for interoperability research, protocol
> documentation, and educational purposes. Use it only with hardware you own, and at your own
> risk — some commands (notably anything OTA/firmware-related) are intentionally NOT exercised by
> this tool because they carry a real risk of bricking the device.

   We welcome contributions from anyone who has access to additional technical information about these glasses. If you have proprietary documentation, firmware binaries, reverse engineering notes, or insights into undocumented BLE commands, please consider sharing them (within legal and ethical boundaries). Submit detailed findings via GitHub issues with clear descriptions, screenshots, or anonymized excerpts. Code contributions that extend protocol coverage or improve the validation suite are especially valuable. Note that all contributions remain confidential and will be used solely to improve protocol understanding and documentation.

---

## Table of Contents

- [Motivation](#motivation)
- [Requirements](#requirements)
- [Installation](#installation)
- [Command-Line Usage](#command-line-usage)
- [Architecture](#architecture)
- [BLE Protocol Overview](#ble-protocol-overview)
- [Test Reference](#test-reference)
- [The "Hi Luma" AI Demo](#the-hi-luma-ai-demo)
- [Environment Variables](#environment-variables)
- [Output Files](#output-files)
- [Known Hardware Behavior](#known-hardware-behavior)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Requirements

- **macOS 14+** (CoreBluetooth's modern async delegate APIs and the bundled Silero-VAD CoreML
  model both target this baseline)
- **Swift 5.9+** / Xcode command-line tools
- Bluetooth enabled, with Terminal (or your IDE) granted Bluetooth permission in
  *System Settings → Privacy & Security → Bluetooth*
- The glasses, powered on and advertising (their BLE name must contain the target substring,
  `E09` by default)
- Optional: a [Mistral AI](https://mistral.ai) API key, only needed for the speech-to-text,
  text-generation, vision, and text-to-speech features (STT/chat/vision/TTS) — every purely BLE
   - **How to get a free Mistral AI key**: Visit [https://mistral.ai](https://mistral.ai), create a free account, then navigate to the "API Keys" section in your dashboard to generate a new API key. The free tier provides a limited number of monthly calls, which is sufficient for testing the speech-to-text, text-generation, and text-to-speech features in the Hi Luma demo. Keep your key secure and regenerate it from the same dashboard if needed.
  test works without it

### Dependencies

Resolved automatically by Swift Package Manager (see `Package.swift`):

- [`onnxruntime-swift-package-manager`](https://github.com/microsoft/onnxruntime-swift-package-manager) —
  ONNX Runtime backend for the bundled Silero Voice Activity Detection (VAD) model
- [`swift-opus`](https://github.com/alta/swift-opus) — Opus codec bindings, used to decode
  captured microphone audio for VAD analysis

Two small VAD model files are bundled as package resources
(`Sources/e09_reverse/Resources/silero-vad.mlmodelc` and `silero_vad.onnx`) — the tool tries a
CoreML backend first (faster on Apple Silicon) and falls back to ONNX Runtime automatically if
CoreML inference isn't available on the host Mac.

---

## Installation

```bash
git clone <this-repo-url>
cd e09_reverse

# Debug build (fast to iterate)
swift build

# Release build (recommended for actual use — faster audio/VAD processing)
swift build -c release
./.build/release/e09_reverse --help
```

Or run directly through SwiftPM without a separate build step:

```bash
swift run e09_reverse --help
```

---

## Command-Line Usage

```
Usage: e09_reverse [OPTIONS] [TARGET_NAME]

Options:
  --help, -h           Display the help message
  --list, -l           List all available tests with their Swift names and descriptions
  --validate, -v       Run all validation tests, in order
  --test TEST_NAMES    Run specific tests only (comma-separated Swift test names)
  --verbose            Display truncated frame data (20 bytes max per notification)
  --debug              Display full frame data for every notification

Output modes:
  (no flag)            Light mode: prints a "." for each BLE notification received
  --verbose            Normal mode: truncated hex dump per notification
  --debug              Debug mode: full hex dump per notification

Examples:
  e09_reverse                                          # Diagnostic scan, light output
  e09_reverse --list                                   # List all tests
  e09_reverse --validate                                # Run the full test suite
  e09_reverse --test validateBattery,validateDeviceInfo # Run just these two tests
  e09_reverse MyGlasses --verbose                       # Custom BLE name substring

Target name defaults to "E09" if not specified — the tool connects to the first
advertising peripheral whose name CONTAINS this substring.
```

Running with no `--test`/`--validate` flag performs a plain diagnostic scan+connect+inspect pass
(useful for discovering GATT services/characteristics on hardware you haven't profiled yet)
without running any test logic.

### Running a single test interactively

Most audio-related tests print detailed on-screen instructions and wait for you to press Enter
before they start listening — read the printed instructions each time, since the exact expected
sequence (say the wake word, wait for a beep, then speak) matters for a clean result.

```bash
swift run e09_reverse --test validatePassiveWakeWordListen
```

---

## Architecture

```
Sources/e09_reverse/
├── main.swift                  Entry point: parses CLI args, starts BleProbe, runs the RunLoop
├── Models.swift                CLI argument parsing, OutputMode, TestDefinition
├── Constants.swift             BLE UUIDs, command/parameter byte constants
├── BleProbe.swift              Core CoreBluetooth central: scanning, framing, test registry,
│                                notification routing, the adaptive audio-capture state machine
├── HiLumaDemo.swift            The end-to-end voice-assistant demo (wake word → STT → tool
│                                routing → photo/vision/time → TTS)
├── MistralAI.swift             Minimal Mistral AI client: STT, TTS, and chat/vision completions
│                                with tool-calling support
├── OpusDecoder.swift            Opus → PCM decoding (feeds the VAD)
├── OggOpusMuxerDemuxer.swift    Builds/parses valid Ogg-Opus container files from raw BLE
│                                Opus packets (RFC 3533 / RFC 7845 compliant)
├── SileroVAD.swift               Voice Activity Detection protocol + shared logic
├── CoreMLSileroVAD.swift         Silero-VAD backend using CoreML (preferred on Apple Silicon)
├── ONNXSileroVAD.swift           Silero-VAD backend using ONNX Runtime (fallback)
└── Resources/                    Bundled Silero-VAD model files (.mlmodelc + .onnx)

Tests/            XCTest unit tests for the VAD and MistralAI modules
Examples/         Small standalone usage example for the MistralAI client
```

**Design principles used throughout:**

- CoreBluetooth's central-manager delegate runs on its **own dedicated queue**, never the main
  queue — test code blocks synchronously while waiting for responses (via `DispatchSemaphore` or
  `Task.sleep`), and doing that on the same queue CoreBluetooth delivers notifications on would
  starve every pending notification until the whole test suite finished.
- Every BLE write that expects a reply is guarded by draining any stale, previously-unconsumed
  notification signal first — otherwise a late/unawaited response from one test can be
  misattributed to the next one.
- Audio is captured and reassembled as **individual Opus packets** (packet boundaries preserved),
  not concatenated into one blob — both the Ogg container writer and the VAD decoder need each
  packet's own boundary to work correctly.

---

## BLE Protocol Overview

This section documents the protocol surface this tool actually talks to. It was derived by
capturing and probing real BLE traffic — not from any vendor documentation — and is necessarily
incomplete outside what's exercised by the tests below.

### GATT Services & Characteristics

| UUID | Role |
|------|------|
| `0000aa12-0000-1000-8000-00805F9B34FB` | Primary custom service |
| `0000aa13-…` (`AA13`) | Command **write** characteristic (app → glasses) |
| `0000aa14-…` (`AA14`) | Command **notify** characteristic (glasses → app), also carries the live microphone audio stream |
| `0000aa15-…` (`AA15`) | Photo-transfer **notify** characteristic (glasses → app), a separate framing used only for JPEG chunk transfer |
| `180F` / `2A19` | Standard Bluetooth SIG **Battery Service** — also exposed alongside the custom service |
| `AE00` / `AE01` (write-without-response) / `AE02` (notify) | A third, undocumented service — believed to belong to the Bluetooth chipset vendor's own OTA/firmware-update SDK. Its exact contents are **not** exercised by this tool; treat it as out of scope. |

### Frame formats

Two distinct framings are used depending on the characteristic:

**Command channel** (`AA13`/`AA14`) — a short, fixed-header frame:

```
[SOF: 2 bytes] [length: 1 byte] [commandId: 1 byte] [payload: N bytes] [checksum: 1 byte]
```

- App → glasses SOF: `0xAB 0x55`
- Glasses → app SOF: `0xAC 0x55`
- Checksum is a simple sum of all preceding bytes modulo 256 (not a polynomial CRC)

**Photo-transfer channel** (`AA15`) — a different, longer framing used only while a photo capture
is in progress:

```
[SOF: 0x52 0x58] … payload (format depends on sub-command) … [footer: 0x58 0x52]
```

Distinguished from the command-channel framing by its own start-of-frame/footer bytes.

### Command/notification IDs used by this tool

A handful of numeric command IDs are deliberately reused for more than one purpose depending on
context (channel and direction) — this is a real property of the protocol, not a bug in this
tool's constants:

| Value | Hex | Meaning on the **command channel** | Meaning on the **photo-transfer channel** |
|-------|-----|--------------------------------------|--------------------------------------------|
| 151 | `0x97` | Wake-word / voice-stream **start** notification | `PHOTO_START` (announces total JPEG size) |
| 152 | `0x98` | — | `PHOTO_TRANS` (one JPEG chunk, prefixed by a 4-byte cumulative offset) |
| 153 | `0x99` | Voice-stream **end** notification | `PHOTO_END` |

Other command IDs referenced by the test suite:

| Hex | Dec | Name | Direction | Purpose |
|-----|-----|------|-----------|---------|
| `0x06` | 6 | `VOICE_COMMAND` | app → glasses | Toggle manual voice-command mode on/off |
| `0x0A` | 10 | `DEVICE_PHOTO_RECOGNITION` | (see notes) | Triggers a wake-word-style notification + a live microphone audio stream |
| `0x16` | 22 | `GET_CAPACITY` | app → glasses | Query storage capacity |
| `0x17` | 23 | `GET_BATTERY` | app → glasses | Query battery level |
| `0x22` | 34 | `TAKE_PHOTO` | app → glasses | Capture a photo (thumbnail or high-quality) |
| `0x25` | 37 | `APP_RECEIVE_WIFI_INFO` | glasses → app | Wi-Fi SSID reply to `OPEN_WIFI` |
| `0x34` | 52 | `RECORD_AUDIO` | app → glasses | Start/stop a **local** voice-memo recording (glasses' own storage — not a BLE stream, see notes below) |
| `0x39` | 57 | `OPEN_WIFI` | app → glasses | Ask the glasses to open a Wi-Fi access point for bulk media import |
| `0x45` | 69 | `ACTION_SYNC` | glasses → app | Spontaneous device-state push (photo/video/audio in progress, gesture, worn/removed, music playback, import state — one boolean flag per bit) |
| `0x46` | 70 | `APP_RECEIVE_VOICE_DATA` | glasses → app | One Opus packet of live microphone audio |
| `0x49` | 73 | `APP_CANCEL_VOICE_RECOGNITION` | app → glasses | Cancel an in-progress voice recognition session |
| `0x51` | 81 | `APP_CANCEL_AI_VOICE` | app → glasses | Cancel the AI's spoken reply |
| `0x55` | 85 | `GET_DEVICE_INFO` | app → glasses | Query BT/ISP/device firmware versions |
| `0x56` | 86 | `APP_STOP_VOICE_RECOGNITION` | app → glasses | Explicitly stop an app-initiated voice-recognition stream |
| `0x57` | 87 | `APP_START_VOICE_RECOGNITION` | app → glasses | Explicitly start a voice-recognition stream (app-controlled: never ends on its own) |
| `0x71` | 113 | `GET_VOICE_ASSISTANT_STATUS` | app → glasses | Query the wake-word/offline-speech assistant status bits |
| `0x72` | 114 | `SET_VOICE_ASSISTANT_STATUS` | app → glasses | Toggle the wake-word/offline-speech assistant status bits |
| `0x95` | 149 | `GET_SUPPORT_FUNCTION` | app → glasses | Query the 32-bit hardware capability bitmask |

### Frame CRC/checksum

Command-channel frames use a trivial checksum: sum every byte from the SOF through the payload,
modulo 256. The photo-transfer channel uses a different, longer scheme (an 8-bit running checksum
plus a 16-bit value across the whole chunk) — see `parseFileFrame`/`buildBleFrame` in
`BleProbe.swift` for the exact byte-level implementation this tool relies on.

---

## Test Reference

Run `e09_reverse --list` at any time for the authoritative, up-to-date list straight from the
source. The table below groups the 18 built-in tests by category and explains what each one
demonstrates.

Tests prefixed `validate*` have a known-good expected outcome (pass/fail is meaningful). Tests
prefixed `probe*` are exploratory — they exercise commands whose real-world behavior wasn't
obvious in advance, so they always "succeed" in the sense of completing the probe; the interesting
part is what gets printed/logged, not a strict pass/fail.

### General device info

| Test | What it demonstrates |
|------|----------------------|
| `validateBattery` | Reads the battery level via `GET_BATTERY`. Demonstrates the basic request/response pattern on the command channel. |
| `validateStorageCapacity` | Reads the glasses' reported internal storage capacity via `GET_CAPACITY`. |
| `validateDeviceInfo` | Reads BT/ISP/device firmware version strings via `GET_DEVICE_INFO`. |
| `validateSupportFunction` | Reads and decodes the 32-bit hardware capability bitmask via `GET_SUPPORT_FUNCTION` — bits reported include AI wake-word support, offline/local voice recognition, quick-volume, wear detection, image stabilization, screen orientation, and an independent factory-reset button, among others. Useful for quickly telling apart hardware/firmware variants. |

### Photo capture

| Test | What it demonstrates |
|------|----------------------|
| `validateTakePhoto` | Triggers `TAKE_PHOTO` (high-quality mode), then waits for and reassembles the complete JPEG transferred separately over the photo-transfer channel (`PHOTO_START`/`PHOTO_TRANS`/`PHOTO_END`), saving it to disk. Demonstrates that the physical shutter/capture completes noticeably before the BLE transfer of the resulting image finishes — a naive implementation that only waits for the initial acknowledgement will silently truncate the photo. |
| `validateTakePhotoSizeConsistency` | Takes 3 photos back-to-back and checks whether the difference between the size `PHOTO_START` announces and the number of bytes actually received is **constant** across captures — a regression test for a systematic under-reporting behavior observed on this hardware (the announced size consistently omits the last chunk). |

### Voice command & assistant status

| Test | What it demonstrates |
|------|----------------------|
| `validateVoiceCommand` | Sends `VOICE_COMMAND` (manual voice-command activation toggle). This command does not produce a direct BLE acknowledgement by design. |
| `validateVoiceAssistantStatus` | Reads the wake-word/offline-speech assistant status byte via `GET_VOICE_ASSISTANT_STATUS`. |
| `validateSetVoiceAssistantStatus` | Writes a modified status byte via `SET_VOICE_ASSISTANT_STATUS`, reads it back to confirm the change stuck, then restores the original value and confirms the restoration too. Since this is a **persistent** device setting (not a session flag), the test always leaves the device exactly as it found it. |

### Audio capture & microphone streaming

| Test | What it demonstrates |
|------|----------------------|
| `validateAudioRecording` | Starts/stops a **local** voice-memo recording via `RECORD_AUDIO`. This is a local-storage toggle, not a BLE audio stream — expect no live microphone packets from this test alone. If `MISTRAL_API_KEY` is set, any audio that *is* captured is automatically transcribed. |
| `probeStartVoiceRecognition` | Sends `APP_START_VOICE_RECOGNITION` and listens for a fixed window before explicitly sending `APP_STOP_VOICE_RECOGNITION`. Demonstrates that this stream is fully app-controlled: it does not end on its own, so a paired stop command is required. |
| `probeDevicePhotoRecognition` | Sends `DEVICE_PHOTO_RECOGNITION` and listens adaptively (stopping on whichever comes first: a genuine end-of-stream marker, VAD-detected silence, or a safety-net timeout). Demonstrates that this command — nominally a glasses→app notification — reliably triggers the same wake-word-style notification **and** live microphone stream a real spoken wake word would, when written by the app instead. |
| `validatePassiveWakeWordListen` | Sends **nothing** over BLE. Arms the same adaptive listening logic and waits for you to physically say the wake word out loud. This isolates whether the synthetic trigger above bypasses any part of the real, acoustically-triggered state machine — spoiler: it doesn't, they behave identically. Once the on-board Voice Activity Detector confirms a sustained silence after real speech, this test proactively sends `APP_STOP_VOICE_RECOGNITION` to test whether an explicit stop command can end a stream that started from a genuine spoken wake word. If `MISTRAL_API_KEY` is set, the captured utterance is transcribed automatically. |
| `probeCancelVoiceRecognitionDuringStream` | Triggers a stream via `DEVICE_PHOTO_RECOGNITION`, waits a few seconds, then sends `APP_CANCEL_VOICE_RECOGNITION` mid-stream and reports whether audio packets stop arriving afterward. |
| `probeCancelAiVoiceDuringStream` | Same idea, but with `APP_CANCEL_AI_VOICE` — nominally meant to cancel the assistant's spoken reply rather than the user's own speech capture, so it may have no observable effect on the incoming microphone stream. |
| `validateActionSyncPassiveListen` | Sends nothing; passively listens for spontaneous `ACTION_SYNC` pushes for a fixed window while you perform a sequence of suggested physical actions (tap, nod, shake, volume buttons, wear/remove), decoding and printing which state-flags each action produced. |

### Wi-Fi bulk media import

| Test | What it demonstrates |
|------|----------------------|
| `probeOpenWifiMediaImport` | Sends `OPEN_WIFI` and decodes the SSID returned via `APP_RECEIVE_WIFI_INFO`. This is a **separate** mechanism from the live BLE audio/photo transfer above — it's how the glasses expose their full-resolution photo/video/audio-memo storage for bulk import over a temporary Wi-Fi access point, rather than the lower-resolution live preview available over BLE. This test only performs the BLE handshake; actually joining the announced network and browsing its file listing is a manual follow-up step. |

### "Hi Luma" AI demo (requires Mistral AI)

| Test | What it demonstrates |
|------|----------------------|
| `validateHiLumaDemo` | The full pipeline described in [The "Hi Luma" AI Demo](#the-hi-luma-ai-demo) below: real wake-word detection → speech-to-text → intent routing (time / photo / scene description / general question) → text-to-speech reply. |

---

## The "Hi Luma" AI Demo

`validateHiLumaDemo` reproduces, using [Mistral AI](https://mistral.ai) instead of any
vendor-specific cloud backend, the kind of voice-assistant experience these glasses are designed
for:

| You say | What happens |
|---------|---------------|
| "Hi Luma, what time is it?" | The assistant answers with the current time |
| "Hi Luma, what am I looking at?" | The glasses take a photo; a vision-capable model describes the scene and objects in it |
| "Hi Luma, take a photo" | The glasses take a photo — no description, just a confirmation |
| "Hi Luma, how do you say 'house' in English?" | The assistant answers directly (a general-knowledge/translation question — no device action needed) |

### Pipeline

1. **Wake word** — the test arms the same real, acoustically-triggered listening logic as
   `validatePassiveWakeWordListen` (nothing is sent over BLE to fake the trigger).
2. **Voice Activity Detection** — captured Opus packets are decoded to PCM and fed to a bundled
   Silero-VAD model (CoreML, falling back to ONNX Runtime) in real time, so the tool knows the
   moment you stop talking instead of guessing from a fixed timeout.
3. **Speech-to-text** — the captured utterance is sent to Mistral's audio transcription endpoint.
4. **Intent routing** — the transcript is sent to a Mistral chat-completion model with three
   callable tools (`get_current_time`, `take_photo_only`, `describe_what_i_see`); the model
   decides whether to call one of them or answer directly.
5. **Action** — `take_photo_only`/`describe_what_i_see` trigger a real `TAKE_PHOTO` capture over
   BLE; `describe_what_i_see` additionally sends the resulting JPEG to a vision-capable model
   along with your original question.
6. **Text-to-speech** — the final reply is synthesized and played back through the current
   default macOS audio output device.

If the glasses are paired to your Mac as a **standard Bluetooth audio device** (a separate,
ordinary Bluetooth pairing — not the BLE/GATT connection this tool otherwise manages) and
selected as that output, step 6 plays through the glasses' own speaker automatically; there is no
special code for this — it's just how macOS routes audio to whatever output device is currently
selected.

Set `MISTRAL_LANGUAGE` (e.g. `en`, `es`, `de`, `it`; defaults to `fr`) to get a localized reply
language and a matching voice for playback.

---

## Environment Variables

| Variable | Required for | Default |
|----------|---------------|---------|
| `MISTRAL_API_KEY` | Automatic transcription of any captured audio, and the entire `validateHiLumaDemo` pipeline | none — STT/demo features are skipped entirely if unset |
| `MISTRAL_LANGUAGE` | Reply language + TTS voice selection in `validateHiLumaDemo`; STT language hint elsewhere | `fr` |

```bash
export MISTRAL_API_KEY="your-key-here"
export MISTRAL_LANGUAGE="en"   # optional
swift run e09_reverse --test validateHiLumaDemo
```

---

## Output Files

Generated in the current working directory unless noted otherwise:

- **Audio**: `<label>_<ISO8601-timestamp>.ogg` — RFC 3533/7845-compliant Ogg Opus files, one per
  capture, decodable by any standard player (`ffplay`, `afplay`, VLC, …)
- **Photos**: `photo_<ISO8601-timestamp>.jpg`
- **Hi Luma demo TTS replies**: written to a temporary file and deleted automatically after
  playback (kept only if playback itself fails, for troubleshooting)

---

## Known Hardware Behavior

A few non-obvious things this tool's test suite surfaced, worth knowing if you're building on top
of this protocol yourself:

- **The live BLE microphone stream does not self-terminate.** Neither a fixed timeout nor
  on-device silence detection reliably ends it — audio packets keep flowing at a steady rate even
  through several seconds of the speaker going quiet. Ending a stream cleanly requires either an
  explicit stop command (which only reliably works for app-initiated streams) or a client-side
  Voice Activity Detector, as implemented here.
- **BLE-transferred photos are a low-resolution preview**, not the full-resolution image the
  on-device camera actually captured. Full-resolution photos, video, and local voice memos are
  only retrievable via the separate Wi-Fi bulk-import mechanism (`OPEN_WIFI`).
- **The `PHOTO_START` announced size under-reports the true JPEG size** by a small, apparently
  constant amount (see `validateTakePhotoSizeConsistency`) — don't use it for strict buffer
  preallocation without leaving headroom.
- **Several commands that look like dead/unused protocol surface from the outside turn out to be
  fully functional** when exercised directly (`APP_START_VOICE_RECOGNITION`,
  `DEVICE_PHOTO_RECOGNITION`) — a reminder that a command's absence from a companion app's normal
  usage doesn't mean the firmware doesn't support it.
- **The assistant audio reply is not intended to play through the glasses via this BLE protocol**
  at all — there is no command anywhere in this surface to push playable audio to the glasses.
  Voice replies are meant to be played on the paired phone (or, in this demo, this Mac) instead —
  unless the glasses are also separately paired as a standard Bluetooth **audio** device, in which
  case ordinary Bluetooth (not BLE) carries the audio, entirely outside this protocol.

---

## Troubleshooting

**Device not found during scan**
- Confirm the glasses are powered on and not already connected to another device (most BLE
  peripherals only accept one central connection at a time)
- Check the advertised name actually contains your target substring — run with no test flags to
  see every nearby peripheral's advertised name and services
- Move closer; BLE range with a phone-grade radio is modest

**Bluetooth permission errors**
- *System Settings → Privacy & Security → Bluetooth* — make sure your terminal/IDE is allowed

**A `probe*`/`validate*` audio test reports no packets at all**
- Make sure you actually spoke within the listening window, and that any required BLE
  acknowledgement was received first (check the printed frame logs)
- `validateAudioRecording` is expected to receive no live packets — see
  [Known Hardware Behavior](#known-hardware-behavior)

**Mistral AI calls fail with 401/422**
- 401: check `MISTRAL_API_KEY` is set and valid
- 422 on `/audio/speech`: make sure you're on a version of this tool where `synthesize()` requests
  `response_format` explicitly and decodes the JSON `audio_data` field — earlier revisions of this
  client had both wrong (see `MistralAI.swift`'s inline comments for the exact history)

---

## License

MIT License — see [LICENSE](LICENSE).
