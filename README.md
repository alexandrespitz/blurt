# Blurt 🦜

**Blurt it out. Your Mac types it. Nothing leaves the machine.**

Blurt is free, open-source, local-only dictation for macOS. Hold a key, talk,
let go — the text lands wherever your cursor is, in most Mac apps, in any of 25
languages, detected automatically mid-sentence. Speech recognition runs on your
Mac's Neural Engine with NVIDIA's Parakeet v3 model. There is no account, no
subscription, no cloud, and no telemetry. Blurt's only network use is the
one-time model download; after that it runs fully offline.

**[Download for macOS](https://github.com/alexandrespitz/blurt/releases/latest/download/Blurt.dmg)** · Apple Silicon, macOS 14+ · MIT licensed

---

## Why this exists

One evening a commercial dictation app froze mid-thought and took a long,
careful dictation with it. The audio had only ever existed in that app's
memory. Blurt was built the same night around one non-negotiable rule:

> **Your voice hits the disk while you speak.** A crash, a force-quit, a
> frozen app — the recording survives, and the next launch finds it,
> transcribes it, and puts it in your history. The most an app crash can cost
> is the last fraction of a second (a power cut, the last two).

Everything else grew from using it daily. It is a personal tool that turned
out to be good enough to share, and it is MIT-licensed because dictation
software is exactly the kind of thing you should be able to read before you
let it listen to you.

## What makes it different

- **Crash-safe by construction.** Audio streams to disk as you speak;
  every recording moves through a write-ahead lifecycle
  (`recording → finalized → transcribed → committed`). Kill the app at any
  point — relaunch converges to exactly one history entry or one visible,
  recoverable recording. Never a silent loss, never a duplicate. There is a
  CLI that kills a recording mid-write and proves the words come back
  (`Scripts/test_recovery.sh`).
- **Local, verifiably.** Transcription (Parakeet v3, CoreML), the optional
  tidy-up pass (Apple Intelligence, on-device), the learning loop — all of it
  on your Mac. Run `lsof -i -p $(pgrep -x Blurt)` while dictating: no sockets.
- **It learns your words — locally.** Add names and jargon it should know.
  Edit any transcript; make the same fix twice and Blurt promotes it to a
  correction rule automatically (visible, vetoable, on your disk).
- **Live preview at conversation speed.** Words trail your voice by well
  under a second. The final text always comes from a clean full pass.
- **25 European languages, zero switching.** English, French, German,
  Spanish, Italian, Portuguese, Polish, Ukrainian… auto-detected, even when
  you change language between sentences.
- **One key, two gestures.** Tap to start/stop, hold for push-to-talk.
  Any modifier or F-key; combos pass through untouched (AZERTY-safe).
- **Gaze Mode** (experimental): hands-free. Blurt listens continuously, your
  pauses cut the sentences, and each one lands in the text box you were
  looking at — pair it with any eye tracker that moves the pointer, or use
  the pointer itself. Nothing is clicked, nothing is rearranged.
- **Optional on-device tidy-up.** Removes "um"s and false starts using
  Apple's local model (macOS 26 + Apple Intelligence). Off by default; the
  raw transcript is always kept.

## Compared to the apps you would otherwise use

Honest table, last verified 26 August 2026 — these products change; check
their sites before deciding.

| | **Blurt** | SuperWhisper | Wispr Flow | Willow Voice | Apple Dictation |
|---|---|---|---|---|---|
| Price | **Free (MIT)** | Freemium + paid | Free tier + paid | Free tier + paid | Free |
| Source | **Open (MIT)** | Closed | Closed | Closed | Closed |
| Audio leaves your Mac | **Never** | No (local models) | Yes (cloud STT) | Yes (cloud) | Sometimes |
| Survives a crash mid-dictation | **Yes, by design** | No | No | No | No |
| Learns your vocabulary | **Yes, on your disk** | Partial | Yes (cloud) | Yes (cloud) | Limited |
| Auto language switching | **Yes (25)** | Model-dependent | Yes | Limited | Manual |
| AI cleanup | On-device only | Cloud + local | Cloud | Cloud | No |
| Gaze / hands-free targeting | **Yes** | No | No | No | No |
| Windows / iOS | No | iOS | Yes | Windows (2026) | Built-in |

Where the closed apps are genuinely ahead: cloud LLM formatting "modes"
(email tone, prompt rewriting), broader language sets via cloud, polish, and
signed/notarized installers. If you want those trade-offs, they are good
products. Blurt's bet is different: **the words you speak into your machine
are yours, and the tool that hears them should be inspectable.**

## Install

1. Download **[Blurt.dmg](https://github.com/alexandrespitz/blurt/releases/latest/download/Blurt.dmg)**, drag Blurt to Applications, open it.
2. macOS will refuse the first launch — Blurt is signed with a developer's own
   certificate, not an Apple-notarized one (there is no Apple developer
   account behind this project, deliberately). Go to **System Settings →
   Privacy & Security**, scroll down, click **Open Anyway**, open again.
3. Onboarding asks for **Microphone** (to hear you) and **Accessibility**
   (to see your dictation key and paste for you), then downloads the model
   (about 480 MB, once, verified against hashes pinned in this repo). After
   that it works fully offline.

Verify your download against the SHA-256 checksum published with each
[release](https://github.com/alexandrespitz/blurt/releases):

```bash
shasum -a 256 ~/Downloads/Blurt.dmg
```

The paranoid path — build it yourself in about five minutes:

```bash
git clone https://github.com/alexandrespitz/blurt && cd blurt
brew install xcodegen
make cert     # one-time: your own local signing identity (no prompts)
make install  # builds, signs, copies to /Applications
```

## Trust, honestly stated

Dictation software is surveillance-shaped. Here is exactly what Blurt does
with its permissions — all of it checkable in this repo:

- **The keyboard tap** sees system key events (that is how global hotkeys
  work on macOS). The [callback](Sources/Services/EventTapService.swift)
  matches your dictation key and passes everything else through untouched.
  Nothing is logged, stored, or sent. This is the single most sensitive piece
  of the app, and it is ~300 lines you can read.
- **Not sandboxed**, because a global event tap cannot exist in the sandbox.
  Mitigated by having no network code at all: the only connection ever made
  is the model download from Hugging Face (inside the
  [FluidAudio](https://github.com/FluidInference/FluidAudio) dependency).
- **Microphone** is captured only while recording (or continuously in Gaze
  Mode, which is opt-in and shows an eye in the menu bar while listening).
- **Your data** lives in `~/Library/Application Support/Blurt` with
  owner-only permissions, excluded from Time Machine. Audio is deleted after
  transcription (configurable: immediately / 1 day / 7 days). History is a
  local JSON you can open, export, or clear.
- **The clipboard caveat:** transcripts go on the normal macOS clipboard, so
  Universal Clipboard syncs them to your other Apple devices and clipboard
  managers can read them. That is inherent to pasting. Gaze Mode's direct
  insertions skip the clipboard entirely by default.
- Grants are pinned to the signing certificate, so app updates do not reset
  your permissions.

Security reports: see [SECURITY.md](SECURITY.md).

## Fork it

This repo is a base, not just an app. MIT means you can build your own
dictation tool on top of it — rebrand it, rip out what you don't want, ship
it. A practical path:

1. Change `bundleIdPrefix` and the bundle identifiers in `project.yml`, and
   `BUNDLE_ID` in `Scripts/build.sh`.
2. Run `make cert` (mints **your** signing identity — never commit it).
3. `make build && make test && make selftest`.

The architecture is deliberately forkable — small files, one subsystem each:

```
Sources/Core       pure logic, no frameworks: hotkey state machine, WAV
                   writer + crash recovery, job lifecycle, segmenter,
                   corrector/learning, history
Sources/Services   one macOS subsystem each: event tap (own thread),
                   recorder, transcription queue, delivery, gaze targeting,
                   permissions, recovery
Sources/App        the coordinator wiring it together
Sources/UI         menu bar, floating pill, dashboard, onboarding
Sources/CLI        blurt-cli: headless testing and fault injection
Tests              59 unit tests, including the crash-boundary and privacy invariants
```

Three design choices worth knowing before you dig in: the keyboard tap runs
on its own thread so a busy UI can never cost a dictation; transcription is
an explicit FIFO queue because actors are reentrant across `await`; and the
finished WAV on disk is always the transcription input — live, recovered,
and retried dictations share one code path, and the file doubles as the
write-ahead log.

## Limits, so you are not surprised

Apple Silicon only (the model runs on the Neural Engine). macOS 14+.
European languages only — no CJK or Arabic (the model's limit; the same SDK
offers Mandarin models if you want to fork in that direction). Gaze Mode's
sentence-splitting is energy-based and can be confused by loud rooms. The
installer is not notarized, so first launch takes the Open Anyway dance.

## Credits

Speech recognition is NVIDIA's
[parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
(CC-BY-4.0), running as CoreML via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) with
conversions by [FluidInference](https://huggingface.co/FluidInference).
The app began life under the model's name before the bird asked for it back.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Built by [Alexandre Spitz](https://github.com/alexandrespitz), with Claude.
MIT — see [LICENSE](LICENSE).
