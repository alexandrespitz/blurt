#!/bin/bash
# Proves the promise this app exists for: kill the process mid-recording and the
# words still come back.
#
# Runs the real WavWriter, kills the process before it can finalize the header
# (exactly what a freeze or force-quit does), then runs the real recovery path
# and checks the transcript.
set -euo pipefail

cd "$(dirname "$0")/.."
CLI="build/Build/Products/Debug/blurt-cli"
[[ -x "$CLI" ]] || { echo "Build the CLI first: make cli"; exit 1; }
[[ -f Fixtures/en_short.wav ]] || { echo "Generate fixtures first: make fixtures"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Simulating a crash mid-recording"
set +e
"$CLI" simulate-crash Fixtures/en_short.wav "$WORK" >"$WORK/crash.log" 2>&1
CODE=$?
set -e
sed 's/^/    /' "$WORK/crash.log"

if [[ $CODE -eq 0 ]]; then
  echo "FAIL: the simulator exited cleanly; it was supposed to die"
  exit 1
fi
echo "    process died with code $CODE (as intended)"

WAV=$(ls "$WORK"/*.wav 2>/dev/null | head -1)
[[ -n "$WAV" ]] || { echo "FAIL: no recording was left behind"; exit 1; }

# The header must still be unfinalized — that is the state we claim to survive.
DECLARED=$(xxd -s 40 -l 4 -e -g 4 "$WAV" | awk '{print $2}')
if [[ "$DECLARED" != "00000000" ]]; then
  echo "FAIL: expected an unfinalized header, found data size 0x$DECLARED"
  exit 1
fi
echo "    left an unfinalized header, as a real crash would"

echo "==> Recovering"
OUT="$WORK/recover.log"
"$CLI" recover "$WORK" >"$OUT" 2>&1 || true
grep -E "^  (repaired|intact|invalid|too short)" "$OUT" | sed 's/^/    /' || true

if grep -qi "quick brown fox" "$OUT"; then
  echo ""
  echo "PASS — the words survived the crash:"
  grep -i "quick brown fox" "$OUT" | tail -1 | sed 's/^/    /'
  exit 0
fi

echo "FAIL: the recovered audio did not transcribe to the expected words"
echo "--- recovery output ---"
cat "$OUT"
exit 1
