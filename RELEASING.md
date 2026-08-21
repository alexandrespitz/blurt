# Releasing Blurt

The whole release is four commands, but the order matters.

```bash
make test                 # 54 unit tests
make selftest             # transcribes fixtures through the real model
make dmg                  # builds, signs, packages dist/Blurt.dmg
shasum -a 256 dist/Blurt.dmg
```

Then:

1. Bump `MARKETING_VERSION` in `project.yml` (it stamps the app and the DMG).
2. `git tag vX.Y.Z && git push --tags`
3. Create the GitHub release for the tag. Upload **two** copies of the DMG:
   `Blurt.dmg` (the stable name — the website's download button points at
   `releases/latest/download/Blurt.dmg`) and `Blurt-X.Y.Z.dmg`. Paste the
   SHA-256 into the notes.

## Signing rules (the part that bites)

- Releases are signed with the **"Blurt Dev"** identity from the dedicated
  keychain at `~/.blurt-signing/` (created once by `make cert`). The signature
  carries an explicit designated requirement pinned to that certificate,
  which is why users' Accessibility and microphone grants survive updates.
- **Never ship an ad-hoc build.** Ad-hoc signatures change identity every
  build, so every update would silently reset users' permission grants — and
  worse, a stale grant *looks* enabled in System Settings while evaluating to
  false. `Scripts/build.sh` fails loudly rather than fall back.
- The signing keychain must never be committed or shared; a leaked key would
  let someone else's binary inherit users' permission grants. Releasing from
  a new machine means running `make cert` there — that mints a *different*
  certificate, so users will re-grant once on their next update. Prefer
  copying `~/.blurt-signing/` between your own machines over minting twice.
- `codesign -d -r- dist/Blurt.app` must print a `certificate leaf`
  requirement, never `cdhash`.
