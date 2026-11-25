#!/usr/bin/env bash
set -euo pipefail

# Headless check for `newsbarctl recommend summary`.
#
# It proves the CLI-side contract without an App window: usage errors exit 2, a
# request against a missing or un-granted App returns app_unavailable (3) or
# not_authorized (4), the payload keeps the field whitelist, no queue file is
# written, and the command never launches NewsBar.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$PROJECT_DIR/.build/debug/newsbarctl"

if [[ ! -x "$CTL" ]]; then
    echo "missing $CTL (run swift build first)" >&2
    exit 1
fi

AGENT_ROOT="${NEWSBAR_AGENT_ROOT:-}"
before="$(pgrep -x NewsBar 2>/dev/null | wc -l | tr -d ' ' || true)"

# 1. The command is discoverable and the window flag is documented.
#    Capture first: `grep -q` closing the pipe early would trip pipefail.
help="$("$CTL" --help)"
grep -q "recommend summary --window 7d|30d" <<<"$help"
grep -q "never writes a command queue" <<<"$help"

# 2. Missing or invalid window is a usage error, not a silent default.
set +e
"$CTL" recommend summary --json >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "missing --window: expected 2, got $status" >&2; exit 1; }

set +e
"$CTL" recommend summary --window 31d --json >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "31d: expected 2, got $status" >&2; exit 1; }

# 3. A real request: the App must answer from its socket or not at all. Without
#    a live grant the only valid answers are 3 (not running) and 4 (refused).
set +e
json="$("$CTL" recommend summary --window 7d --json 2>/dev/null)"
status=$?
set -e

python3 - "$json" "$status" <<'PY'
import json
import sys

raw, status = sys.argv[1], int(sys.argv[2])
allowed = {0: {"ok", "insufficient_data"}, 3: {"app_unavailable"}, 4: {"not_authorized", "rate_limited"}}
assert status in allowed, f"unexpected exit code {status}: {raw}"
reply = json.loads(raw)
assert reply.get("status") in allowed[status], f"status {reply.get('status')} does not match exit {status}"
assert reply.get("schemaVersion") == 1
assert reply.get("metricDefinitionVersion") == 1
assert reply.get("view") == "overview"
forbidden = {"title", "url", "source", "contentKey", "exposureID", "attemptID"}
assert not (forbidden & set(reply)), f"unexpected fields {forbidden & set(reply)}"
if status != 0:
    assert "counts" not in reply, "a refused reply must not carry counts"
print(f"status={reply['status']} exit={status}")
PY

# 4. No queue file, no launch.
if [[ -n "$AGENT_ROOT" && -n "$(ls -A "$AGENT_ROOT" 2>/dev/null)" ]]; then
    echo "recommend summary wrote to NEWSBAR_AGENT_ROOT: $(ls -A "$AGENT_ROOT")" >&2
    exit 1
fi
after="$(pgrep -x NewsBar 2>/dev/null | wc -l | tr -d ' ' || true)"
if [[ "$after" -gt "$before" ]]; then
    echo "recommend summary launched NewsBar ($before -> $after)" >&2
    exit 1
fi

echo "recommend summary contract holds (exit $status, no queue, no launch)"
