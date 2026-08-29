# Security

Blurt asks for the two most sensitive permissions a Mac app can hold — the
microphone and Accessibility — so its security posture is stated here
plainly, and the code that backs every claim is short enough to read.

## Threat model, in one page

**What Blurt does with its permissions**

| Capability | What it is used for | Where to verify |
|---|---|---|
| Microphone | Captured only while you dictate; in Gaze Mode, continuously while the mode is on (menu bar shows an eye). Gaze Mode never survives a relaunch — continuous listening always requires turning it on again | `Sources/Services/RecorderEngine.swift` |
| Keyboard event tap | Matches your dictation key; every other event passes through untouched. Required for a global hotkey | `Sources/Services/EventTapService.swift` |
| Accessibility (paste / insert) | Synthesizes ⌘V, or inserts text into the box you aimed at in Gaze Mode | `Sources/Services/DeliveryService.swift`, `GazeTargetService.swift` |

**Network:** the app contains no networking code. The single network activity
is the one-time model download (about 480 MB) from Hugging Face, performed by
the [FluidAudio](https://github.com/FluidInference/FluidAudio) dependency
(pinned to an immutable commit). Verify at runtime:
`lsof -i -p $(pgrep -x Blurt)`.

**Model integrity:** the speech model is not shipped inside the app, and it is
fetched from a mutable branch — so every file is checked against SHA-256
hashes pinned in `Sources/Core/ModelIntegrity.swift` before Core ML is asked
to load it. Weights that do not match the ones this build was tested against
are refused, with an explanation. Regenerate them with
`Scripts/pin_model_hashes.sh` only when deliberately adopting a new upstream
model, and re-run `make selftest` before committing. Advanced users who want
to run newer upstream weights can opt out explicitly:
`defaults write com.alexspitz.blurt allowUnverifiedModel -bool true`.

**Storage — the complete inventory:** transcripts, learned vocabulary,
recordings and a small state log live in `~/Library/Application Support/Blurt`
(directories 0700, files 0600; recordings and the log excluded from Time
Machine). The log carries app names and timings, never transcript text. The
downloaded speech model lives in `~/Library/Application Support/FluidAudio`.
Settings live in the `com.alexspitz.blurt` preferences domain. Audio is
deleted after transcription per your retention setting; "Clear History" also
strips transcript copies from retained recording manifests, and "Delete All
Blurt Data" in the dashboard removes everything above except the model.
Nothing is obfuscated — history and learned rules are plain JSON you can
open. To uninstall completely: delete the app, both Application Support
folders, and run `defaults delete com.alexspitz.blurt`.

**Deliberate non-goals and honest weaknesses**

- **Not sandboxed.** A global event tap cannot exist inside the App Sandbox.
  The compensating control is the absence of network code and the smallness
  of the codebase.
- **Not notarized.** Releases are signed with a project-local certificate,
  not an Apple Developer ID. macOS will warn on first launch. Verify the
  SHA-256 checksum published with each release, or build from source.
- **Clipboard exposure.** Pasted transcripts transit the system clipboard,
  which Universal Clipboard syncs across your Apple devices and clipboard
  managers can read. This is inherent to pasting on macOS.
- **Secure fields.** Blurt refuses to paste when secure keyboard input is
  active or the focused field is a password field, and never chooses secure
  fields as Gaze Mode targets.
- **Dictated secrets are still text.** If you speak a password, it will be
  typed, kept in history (unless history is off), and put on the clipboard —
  same as typing it yourself, but worth saying.

## Supported versions

The latest release only.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository
(Security → Report a vulnerability), or open an issue for anything that is
not sensitive. Reports are read by a single maintainer; expect an answer
within a week, not within hours.
