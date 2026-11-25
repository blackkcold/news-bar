#!/usr/bin/env bash
set -euo pipefail

# Background checks for agents and CI. Nothing here launches a visible App
# window or touches the store of a running NewsBar: tests use TestIsolation and
# the launch probe runs with a prohibited activation policy.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TIER="headless"
JSON=0
NO_BUILD=0

usage() {
    cat <<'TEXT'
Usage: scripts/agent-test.sh [--tier headless|render|launch|all] [--json] [--no-build]

  headless   Logic + parser + cache + controller tests and CLI checks.
             Opens no window. This is the default.
  render     Reader/monitor snapshots plus the off-screen render-reader.
             Windows stay off-screen and are never made key.
  launch     Runs the packaged app entry through --launch-probe and proves the
             main actor is still schedulable while AppKit's run loop runs.
  all        Full swift test suite plus render and launch checks.

  --json     Print one JSON report at the end.
  --no-build Skip the initial swift build and use .build/debug/NewsBar as is.

Exit code 0 means every step passed.
TEXT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)
            TIER="${2:-}"
            shift 2
            ;;
        --json)
            JSON=1
            shift
            ;;
        --no-build)
            NO_BUILD=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

case "$TIER" in
    headless|render|launch|all) ;;
    *)
        echo "Unknown tier: $TIER" >&2
        usage
        exit 2
        ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$PROJECT_DIR/.build/agent-test/$STAMP"
STEPS_FILE="$LOG_DIR/steps.tsv"
BIN="$PROJECT_DIR/.build/debug/NewsBar"
AGENT_BIN="$PROJECT_DIR/.build/debug/NewsBarAgent"
FIXTURE="$PROJECT_DIR/Tests/NewsBarHeadlessTests/Fixtures/reader.json"
mkdir -p "$LOG_DIR"
: > "$STEPS_FILE"

# Isolate any agent queue. The v3.4.1 app no longer exposes --agent; the
# variable stays so the v3.4.2 agent executable inherits the same convention.
export NEWSBAR_AGENT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/newsbar-agent.XXXXXX")"
export NEWSBAR_TEST_HEADLESS=1
trap 'rm -rf "$NEWSBAR_AGENT_ROOT"' EXIT

RUNNING="$(pgrep -x NewsBar 2>/dev/null | wc -l | tr -d ' ' || true)"
echo "NewsBar instances running: $RUNNING (left untouched)"

FAILED=0

run_step() {
    local name="$1"
    shift
    local log="$LOG_DIR/$name.log"
    local status=0
    local tests=""

    echo "▶ $name"
    "$@" >"$log" 2>&1 || status=$?
    tests="$(grep -Eo 'Executed [0-9]+ tests' "$log" | tail -1 | grep -Eo '[0-9]+' || true)"
    printf '%s\t%d\t%s\t%s\n' "$name" "$status" "$tests" "$log" >>"$STEPS_FILE"

    if [[ "$status" -ne 0 ]]; then
        FAILED=1
        echo "  ✗ exit $status"
        tail -25 "$log"
    else
        if [[ -n "$tests" ]]; then
            echo "  ✓ $tests tests"
        else
            echo "  ✓"
        fi
    fi
}

if [[ "$NO_BUILD" -eq 0 ]]; then
    run_step build swift build
fi

HEADLESS_FILTER='AgentHeadlessTests|WeiboCommentControllerTests|WeiboCommentCacheTests|WeiboCommentParserTests|FollowingFeedModelTests|WeiboCommentServiceTests'
RENDER_FILTER='FollowingReaderRenderingTests|WeiboMonitorRenderingTests'

if [[ "$TIER" == "headless" || "$TIER" == "all" ]]; then
    run_step headless-tests swift test --filter "$HEADLESS_FILTER"
    run_step agent-check "$AGENT_BIN" check
    run_step agent-store-summary "$AGENT_BIN" store-summary
    run_step agent-doctor "$AGENT_BIN" doctor
    run_step recommend-cli bash scripts/check-recommend-cli.sh
fi

if [[ "$TIER" == "render" || "$TIER" == "all" ]]; then
    run_step render-tests swift test --filter "$RENDER_FILTER"
    run_step render-modern "$AGENT_BIN" render-reader "$FIXTURE" \
        --out "$LOG_DIR/reader-modern-zh.png"
    run_step render-retro "$AGENT_BIN" render-reader "$FIXTURE" \
        --theme retroEditorial --out "$LOG_DIR/reader-retro-zh.png"
    run_step render-narrow "$AGENT_BIN" render-reader "$FIXTURE" \
        --width 579 --height 860 --out "$LOG_DIR/reader-960-modern-zh.png"
fi

if [[ "$TIER" == "launch" || "$TIER" == "all" ]]; then
    # 45s covers a cold debug launch; the alarm remains active across exec.
    run_step launch-probe \
        perl -e 'alarm 45; exec @ARGV' -- \
        "$BIN" --launch-probe "$LOG_DIR/launch-probe.json"
    run_step launch-probe-assert \
        bash scripts/check-launch-probe.sh "$LOG_DIR/launch-probe.json"
fi

if [[ "$TIER" == "all" ]]; then
    run_step full-tests swift test
fi

if [[ "$JSON" -eq 1 ]]; then
    python3 - "$TIER" "$FAILED" "$RUNNING" "$STEPS_FILE" "$LOG_DIR" <<'PY'
import json
import sys

tier, failed, running, steps_path, log_dir = sys.argv[1:6]
steps = []
with open(steps_path, encoding="utf-8") as handle:
    for line in handle:
        name, exit_code, tests, log = line.rstrip("\n").split("\t")
        steps.append({
            "name": name,
            "exit": int(exit_code),
            "tests": int(tests) if tests else None,
            "log": log,
        })
print(json.dumps({
    "tier": tier,
    "ok": failed == "0",
    "runningInstances": int(running),
    "logDirectory": log_dir,
    "steps": steps,
}, indent=2))
PY
else
    echo
    echo "Tier: $TIER"
    echo "Logs: $LOG_DIR"
    if [[ "$FAILED" -eq 0 ]]; then
        echo "Result: PASS"
    else
        echo "Result: FAIL"
    fi
fi

exit "$FAILED"
