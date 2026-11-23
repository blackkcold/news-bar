#!/usr/bin/env bash
set -euo pipefail

# The launch probe must have entered the AppKit run loop AND run a main-actor
# task. `enteredRun` alone means the app crashed or exited before app.run();
# both keys missing means the app never started.

PROBE="${1:-}"
if [[ -z "$PROBE" ]]; then
    echo "usage: check-launch-probe.sh <probe.json>" >&2
    exit 2
fi

if [[ ! -s "$PROBE" ]]; then
    echo "launch probe file missing: $PROBE" >&2
    exit 1
fi

python3 - "$PROBE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

if data.get("enteredRun") is not True:
    raise SystemExit("launch probe did not enter the run loop: %r" % (data,))
if data.get("mainActorTask") is not True:
    raise SystemExit("main actor was starved (enteredRun only): %r" % (data,))

print("launch probe ok")
PY
