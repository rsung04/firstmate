#!/usr/bin/env bash
# Thin provider-neutral quality-learning adapter for firstmate task briefs and
# PR acceptance evidence.
# Usage:
#   fm-quality-learning.sh activate <worktree> <brief-path>
#     Detect a repo-owned quality harness, refresh the marker-bounded brief
#     section in place, and print zero or more meta lines to stdout.
#   fm-quality-learning.sh validate <task-id> <pr-head> <meta-path>
#     Validate an activated task's exact-head Cloud receipt, preserve it as a
#     task-owned immutable copy when newly provided, or reuse the preserved copy
#     when the fresh PR head still matches it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

HARNESS_DOC="docs/workflows/quality-learning-harness.md"
HARNESS_CHECKER="scripts/ci/check-quality-learning.py"
BRIEF_MARKER_START='<!-- firstmate:quality-learning:start -->'
BRIEF_MARKER_END='<!-- firstmate:quality-learning:end -->'
RECEIPT_BASENAME="quality-learning-cloud-receipt"
PRESERVED_DIRNAME="quality-learning-receipts"

usage() {
  cat <<'EOF'
Usage:
  fm-quality-learning.sh activate <worktree> <brief-path>
  fm-quality-learning.sh validate <task-id> <pr-head> <meta-path>
EOF
}

meta_value() {  # <meta-path> <key>
  local meta=$1 key=$2
  grep "^$key=" "$meta" | tail -1 | cut -d= -f2- || true
}

receipt_path_for_task() {  # <task-id>
  printf '%s/%s/%s.json\n' "$DATA" "$1" "$RECEIPT_BASENAME"
}

receipt_source_path_for_task() {  # <task-id>
  printf '%s/%s/%s.source-url\n' "$DATA" "$1" "$RECEIPT_BASENAME"
}

preserved_receipt_path() {  # <task-id> <candidate-sha>
  printf '%s/%s/%s/%s.json\n' "$DATA" "$1" "$PRESERVED_DIRNAME" "$2"
}

preserved_meta_path() {  # <task-id> <candidate-sha>
  printf '%s/%s/%s/%s.sha256\n' "$DATA" "$1" "$PRESERVED_DIRNAME" "$2"
}

require_non_empty_file() {  # <path> <label>
  local path=$1 label=$2 value
  [ -r "$path" ] || { echo "error: $label is missing or unreadable at $path" >&2; return 1; }
  value=$(head -n 1 "$path" | tr -d '\r' || true)
  [ -n "$value" ] || { echo "error: $label at $path must not be empty" >&2; return 1; }
  printf '%s\n' "$value"
}

sha256_file() {  # <path>
  shasum -a 256 "$1" | awk '{print $1}'
}

replace_brief_section() {  # <brief-path> <section-text>
  local brief=$1 section=$2 tmp
  tmp=$(mktemp)
  python3 - "$brief" "$tmp" "$section" "$BRIEF_MARKER_START" "$BRIEF_MARKER_END" <<'PY'
from pathlib import Path
import sys

brief_path = Path(sys.argv[1])
tmp_path = Path(sys.argv[2])
section = sys.argv[3]
start = sys.argv[4]
end = sys.argv[5]

text = brief_path.read_text(encoding="utf-8")
if start in text and end in text:
    prefix, rest = text.split(start, 1)
    _, suffix = rest.split(end, 1)
    updated = prefix + section + suffix
elif "\n# Setup\n" in text:
    updated = text.replace("\n# Setup\n", f"\n{section}\n# Setup\n", 1)
else:
    updated = text.rstrip("\n") + "\n\n" + section + "\n"
tmp_path.write_text(updated, encoding="utf-8")
PY
  mv "$tmp" "$brief"
}

activate() {
  local wt=${1:?usage: activate <worktree> <brief-path>} brief=${2:?usage: activate <worktree> <brief-path>}
  local doc checker base_sha context_json registry_digest section
  doc="$wt/$HARNESS_DOC"
  checker="$wt/$HARNESS_CHECKER"
  [ -f "$doc" ] && [ -f "$checker" ] || return 0

  base_sha=$(git -C "$wt" rev-parse HEAD)
  context_json=$(
    cd "$wt" &&
      python3 "$HARNESS_CHECKER" --mode context-only --base-sha "$base_sha"
  )
  registry_digest=$(printf '%s' "$context_json" | python3 -c '
import json, re, sys
payload = json.load(sys.stdin)
digest = payload.get("registry_digest", "")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("registry_digest missing or malformed")
sys.stdout.write(digest)
')

  section=$(cat <<EOF
$BRIEF_MARKER_START
## Quality Learning
This repository owns a provider-neutral quality-learning harness.
base_sha: \`$base_sha\`
registry_digest: \`$registry_digest\`
Run it before implementation with the intended \`--path\` and \`--risk-flag\` values:
\`\`\`bash
python3 scripts/ci/check-quality-learning.py \\
  --mode context-only \\
  --base-sha $base_sha \\
  --path <intended-path> \\
  --risk-flag <risk-flag>
\`\`\`
Read every returned \`owning_doc_refs\` entry before implementation.
Recompute the same context-only command whenever your intended path or risk scope changes materially.
$BRIEF_MARKER_END
EOF
)
  replace_brief_section "$brief" "$section"

  printf '%s\n' "quality_learning=active"
  printf '%s\n' "quality_learning_base_sha=$base_sha"
  printf '%s\n' "quality_learning_registry_digest=$registry_digest"
}

validate_receipt_payload() {  # <receipt-path> <candidate-sha> <base-sha> <digest>
  local receipt_path=$1 candidate_sha=$2 base_sha=$3 digest=$4
  python3 - "$receipt_path" "$candidate_sha" "$base_sha" "$digest" <<'PY'
import json
import re
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])
candidate_sha = sys.argv[2]
base_sha = sys.argv[3]
digest = sys.argv[4]
exact_sha = re.compile(r"^[0-9a-f]{40}$")
errors = []

try:
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    errors.append(f"exact-head Cloud receipt is missing at {receipt_path}")
    receipt = {}
except json.JSONDecodeError as exc:
    errors.append(f"exact-head Cloud receipt at {receipt_path} is not valid JSON: {exc}")
    receipt = {}

if receipt:
    if receipt.get("schema") != "flowslate.codex_cloud_ci.v1":
        errors.append("exact-head Cloud receipt schema must be flowslate.codex_cloud_ci.v1")
    for key in ("candidate_sha", "base_sha", "checked_out_sha"):
        value = receipt.get(key)
        if not isinstance(value, str) or not exact_sha.fullmatch(value):
            errors.append(f"exact-head Cloud receipt field {key} must be an exact lowercase SHA")
    if receipt.get("candidate_sha") != candidate_sha:
        errors.append("exact-head Cloud receipt candidate_sha does not match the fresh PR head")
    if receipt.get("checked_out_sha") != candidate_sha:
        errors.append("exact-head Cloud receipt checked_out_sha does not match the fresh PR head")
    if receipt.get("base_sha") != base_sha:
        errors.append("exact-head Cloud receipt base_sha does not match the activated quality base")
    if receipt.get("status") != "passed":
        errors.append("exact-head Cloud receipt status must be passed")
    if receipt.get("cleanup_status") != "verified":
        errors.append("exact-head Cloud receipt cleanup_status must be verified")

    ql = receipt.get("quality_learning")
    if not isinstance(ql, dict):
        errors.append("exact-head Cloud receipt is missing the additive quality_learning field")
    else:
        if ql.get("candidate_sha") != candidate_sha:
          errors.append("quality_learning candidate_sha does not match the fresh PR head")
        if ql.get("registry_base_sha") != base_sha:
          errors.append("quality_learning registry_base_sha does not match the activated quality base")
        if ql.get("registry_digest") != digest:
          errors.append("quality_learning registry_digest does not match the activated registry digest")
        if ql.get("fact_source") != "changed_files_only":
          errors.append("quality_learning fact_source must be changed_files_only")
        status = ql.get("status")
        if status in {"not_applicable", "environment_failure"}:
          errors.append(f"quality_learning status {status} is not acceptable for handoff")
        elif not isinstance(status, str) or not status:
          errors.append("quality_learning status must be a non-empty string")

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

preserve_receipt() {  # <task-id> <candidate-sha> <receipt-path> <source-url>
  local task_id=$1 candidate_sha=$2 receipt_path=$3 source_url=$4
  local preserved_dir preserved_receipt preserved_meta digest existing_source existing_digest
  preserved_dir="$DATA/$task_id/$PRESERVED_DIRNAME"
  preserved_receipt=$(preserved_receipt_path "$task_id" "$candidate_sha")
  preserved_meta=$(preserved_meta_path "$task_id" "$candidate_sha")
  digest=$(sha256_file "$receipt_path")

  mkdir -p "$preserved_dir"
  if [ -e "$preserved_receipt" ] || [ -e "$preserved_meta" ]; then
    [ -r "$preserved_receipt" ] || { echo "error: preserved receipt copy is unreadable at $preserved_receipt" >&2; return 1; }
    [ -r "$preserved_meta" ] || { echo "error: preserved receipt metadata is unreadable at $preserved_meta" >&2; return 1; }
    cmp -s "$receipt_path" "$preserved_receipt" || {
      echo "error: immutable preserved receipt for $candidate_sha differs from the newly supplied receipt" >&2
      return 1
    }
    existing_source=$(meta_value "$preserved_meta" source_url)
    existing_digest=$(meta_value "$preserved_meta" sha256)
    [ "$existing_source" = "$source_url" ] || {
      echo "error: immutable preserved receipt metadata for $candidate_sha carries a different source_url" >&2
      return 1
    }
    [ "$existing_digest" = "$digest" ] || {
      echo "error: immutable preserved receipt metadata for $candidate_sha carries a different sha256" >&2
      return 1
    }
    return 0
  fi

  cp "$receipt_path" "$preserved_receipt"
  cat > "$preserved_meta" <<EOF
sha256=$digest
source_url=$source_url
EOF
}

validate() {
  local task_id=${1:?usage: validate <task-id> <pr-head> <meta-path>}
  local pr_head=${2-}
  local meta=${3:?usage: validate <task-id> <pr-head> <meta-path>}
  local active base_sha digest receipt_path source_path preserved_receipt preserved_meta source_url

  active=$(meta_value "$meta" quality_learning)
  [ "$active" = active ] || return 0
  case "$pr_head" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      [ "${#pr_head}" -eq 40 ] || {
        echo "error: activated quality-learning task requires a fresh PR head before handoff" >&2
        return 1
      }
      ;;
    *)
      echo "error: activated quality-learning task requires a fresh PR head before handoff" >&2
      return 1
      ;;
  esac
  base_sha=$(meta_value "$meta" quality_learning_base_sha)
  digest=$(meta_value "$meta" quality_learning_registry_digest)
  [ -n "$base_sha" ] || { echo "error: activated quality-learning task is missing quality_learning_base_sha metadata" >&2; return 1; }
  [ -n "$digest" ] || { echo "error: activated quality-learning task is missing quality_learning_registry_digest metadata" >&2; return 1; }

  receipt_path=$(receipt_path_for_task "$task_id")
  source_path=$(receipt_source_path_for_task "$task_id")
  preserved_receipt=$(preserved_receipt_path "$task_id" "$pr_head")
  preserved_meta=$(preserved_meta_path "$task_id" "$pr_head")

  if [ -e "$receipt_path" ] || [ -e "$source_path" ]; then
    source_url=$(require_non_empty_file "$source_path" "quality-learning receipt source_url")
    case "$source_url" in
      *://*) ;;
      *)
        echo "error: quality-learning receipt source_url must be a URL" >&2
        return 1
        ;;
    esac
    validate_receipt_payload "$receipt_path" "$pr_head" "$base_sha" "$digest"
    preserve_receipt "$task_id" "$pr_head" "$receipt_path" "$source_url"
    return 0
  fi

  [ -r "$preserved_receipt" ] || {
    echo "error: activated quality-learning task requires a readable exact-head Cloud receipt and source URL for the fresh PR head $pr_head" >&2
    return 1
  }
  [ -r "$preserved_meta" ] || {
    echo "error: activated quality-learning task requires preserved receipt metadata for the fresh PR head $pr_head" >&2
    return 1
  }
  source_url=$(meta_value "$preserved_meta" source_url)
  [ -n "$source_url" ] || {
    echo "error: preserved receipt metadata for $pr_head is missing source_url" >&2
    return 1
  }
  validate_receipt_payload "$preserved_receipt" "$pr_head" "$base_sha" "$digest"
}

case "${1:-}" in
  activate)
    shift
    activate "$@"
    ;;
  validate)
    shift
    validate "$@"
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    echo "error: unknown subcommand '$1'" >&2
    usage >&2
    exit 1
    ;;
esac
