# Contributing

Blurt is a small, opinionated codebase maintained by one person in spare
time. Contributions are welcome; patience is required.

## Getting a dev environment

```bash
brew install xcodegen
git clone https://github.com/alexandrespitz/blurt && cd blurt
make cert       # one-time: local signing identity (keeps permission grants
                # stable across your rebuilds; never leaves your machine)
make build      # dist/Blurt.app
make test       # unit tests — fast, no model needed
make fixtures   # text-to-speech test audio
make selftest   # downloads the model (~1 GB, once) and transcribes fixtures
```

Requires Xcode 16+ and Apple Silicon. `Scripts/test_recovery.sh` runs the
crash-recovery proof end to end.

## What makes a good change here

- **The invariant is sacred:** after termination at any point, relaunch
  converges to exactly one history entry or one visible, recoverable
  recording — never silent loss, never duplicates, never a replayed paste.
  `Tests/` encodes this; changes that touch the recording lifecycle need
  tests at the same standard.
- **Local-only is not negotiable.** PRs that add telemetry, accounts, or
  network calls (beyond the existing model download) will be declined
  regardless of quality. Fork freely instead — that is what the MIT license
  is for.
- **Pure logic goes in `Sources/Core`** (no AppKit/AVFoundation imports),
  where it can be unit-tested. System integration lives in
  `Sources/Services`, one subsystem per file.
- Match the codebase's comment style: comments explain constraints the code
  cannot show, not what the next line does.

## Filing issues

Include macOS version, chip, and the tail of
`~/Library/Application Support/Blurt/blurt.log` (it contains timings and
state transitions, never your transcripts — but skim it before pasting).
