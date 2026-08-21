#!/bin/bash
# Generates the speech fixtures the selftest transcribes, using macOS's own
# text-to-speech. Voice availability differs per machine, so each language
# probes a list and takes the first one installed.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Fixtures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pick_voice() {
  for candidate in "$@"; do
    if say -v '?' | grep -q "^${candidate} "; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

render() {
  local voice="$1" text="$2" out="$3" rate="${4:-170}"
  say -v "$voice" -r "$rate" -o "$TMP/raw.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/raw.aiff" "Fixtures/$out"
  echo "    Fixtures/$out  ($voice)"
}

EN_VOICE=$(pick_voice Daniel Alex Fred Albert Samantha) || {
  echo "No English voice found; install one in System Settings → Accessibility → Spoken Content"
  exit 1
}
FR_VOICE=$(pick_voice Thomas Jacques Amelie "Amélie" Audrey) || FR_VOICE=""

echo "==> Rendering fixtures"
render "$EN_VOICE" \
  "The quick brown fox jumps over the lazy dog and runs into the forest." \
  en_short.wav

if [[ -n "$FR_VOICE" ]]; then
  render "$FR_VOICE" \
    "Bonjour, ceci est un test de dictée vocale, merci beaucoup." \
    fr_short.wav
else
  echo "    (no French voice installed — skipping fr_short.wav)"
fi

LONG="The quick brown fox jumps over the lazy dog and runs into the forest. \
Speech recognition on this machine happens entirely on the neural engine, \
which means nothing at all is sent over the network. \
This paragraph exists to be long enough that the model has to split the audio \
into several chunks and stitch the results back together."
render "$EN_VOICE" "$LONG $LONG $LONG" en_long.wav 165

# Two seconds of true silence: the model must not invent words for it.
afconvert -f WAVE -d LEI16@16000 -c 1 /dev/zero Fixtures/silence.wav 2>/dev/null || {
  python3 - <<'PY'
import struct, wave
with wave.open("Fixtures/silence.wav", "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"\x00\x00" * 32000)
PY
}
echo "    Fixtures/silence.wav"

echo "==> Done"
ls -lh Fixtures/*.wav | awk '{print "    " $9 "  " $5}'
