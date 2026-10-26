#!/bin/bash
set -euo pipefail

# Generate the repository guides from the bundled single source JSON.
# Usage:
#   bash scripts/sync-recommendation-guide.sh           # write docs
#   bash scripts/sync-recommendation-guide.sh --check   # verify, no writes

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-write}"

case "$MODE" in
    write|--check) ;;
    -h|--help)
        echo "Usage: bash scripts/sync-recommendation-guide.sh [--check]"
        exit 0
        ;;
    *)
        echo "Unknown argument: $MODE" >&2
        echo "Usage: bash scripts/sync-recommendation-guide.sh [--check]" >&2
        exit 2
        ;;
esac

python3 - "$PROJECT_DIR" "$MODE" <<'PY'
import difflib
import json
import sys
from pathlib import Path

project = Path(sys.argv[1])
mode = sys.argv[2]
source = project / "Sources/NewsBar/Resources/recommendation-guide.json"
targets = {
    "zh": project / "docs/recommendations-explained.zh-CN.md",
    "en": project / "docs/recommendations-explained.md",
}
required = [
    "overview", "features", "scoring", "diversity",
    "telemetry", "privacy", "controls", "limitations",
]

document = json.loads(source.read_text(encoding="utf-8"))
if document.get("schemaVersion") != 1:
    raise SystemExit(f"unsupported schemaVersion: {document.get('schemaVersion')!r}")

sections = document.get("sections")
if not isinstance(sections, list):
    raise SystemExit("sections must be an array")

ids = [section.get("id") for section in sections]
if ids != required:
    raise SystemExit(f"section ids/order must be {required}, got {ids}")

for key in ("title", "notice"):
    block = document.get(key)
    if not isinstance(block, dict):
        raise SystemExit(f"{key} must be an object with zh/en")
    for lang in ("zh", "en"):
        value = block.get(lang, "")
        if not isinstance(value, str) or not value.strip():
            raise SystemExit(f"{key}.{lang} is empty")

for section in sections:
    for key in ("title", "body"):
        for lang in ("zh", "en"):
            value = section.get(key, {}).get(lang, "")
            if not isinstance(value, str) or not value.strip():
                raise SystemExit(f"section {section.get('id')} has empty {key}.{lang}")

def render(lang):
    title = document["title"][lang]
    notice = document["notice"][lang]
    parts = [f"# {title}\n\n> {notice}\n\n"]
    for section in sections:
        parts.append(f"## {section['title'][lang]}\n\n{section['body'][lang]}\n\n")
    return "".join(parts)

failed = False
for lang, target in targets.items():
    generated = render(lang)
    if mode == "--check":
        try:
            current = target.read_text(encoding="utf-8")
        except FileNotFoundError:
            print(f"MISSING {target.relative_to(project)}", file=sys.stderr)
            failed = True
            continue
        if current != generated:
            print(f"OUTDATED {target.relative_to(project)}", file=sys.stderr)
            diff = difflib.unified_diff(
                current.splitlines(keepends=True),
                generated.splitlines(keepends=True),
                fromfile=str(target.relative_to(project)),
                tofile="generated",
            )
            sys.stderr.writelines(diff)
            failed = True
        else:
            print(f"OK {target.relative_to(project)}")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_text(encoding="utf-8") == generated:
            print(f"UNCHANGED {target.relative_to(project)}")
        else:
            target.write_text(generated, encoding="utf-8")
            print(f"WROTE {target.relative_to(project)}")

if failed:
    raise SystemExit(1)
PY
