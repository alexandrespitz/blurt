# Security

Blurt asks for the two most sensitive permissions a Mac app can hold — the
microphone and Accessibility — so its security posture is stated here
plainly, and the code that backs every claim is short enough to read.

## Threat model, in one page

**What Blurt does with its permissions**

| Capability | What it is used for | Where to verify |
|---|---|---|
| Microphone | Captured only while you dictate; in Gaze Mode, continuously while the mode is on (menu bar shows an eye) | `Sources/Services/RecorderEngine.swift` |
| Keyboard event tap | Matches your dictation key; every other event passes through untouched. Required for a global hotkey | `Sources/Services/EventTapService.swift` |
| Accessibility (paste / insert) | Synthesizes ⌘V, or inserts text into the box you aimed at in Gaze Mode | `Sources/Services/DeliveryService.swift`, `GazeTargetService.swift` |

**Network:** the app contains no networking code. The single network activity
is the one-time model download from Hugging Face, performed by the
[FluidAudio](https://github.com/FluidInference/FluidAudio) dependency (pinned
by exact version). Verify at runtime: `lsof -i -p $(pgrep -x Blurt)`.

**Storage:** everything lives in `~/Library/Application Support/Blurt`
(directories 0700, files 0600, recordings excluded from Time Machine). Audio
is deleted after transcription per your retention setting. Nothing is
obfuscated — history and learned rules are plain JSON you can open.

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
