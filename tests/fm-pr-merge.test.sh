#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

RUN_RC=0
QL_CASE_DIR=
QL_CANDIDATE_SHA=
QL_BASE_SHA=
QL_DIGEST=
QL_SOURCE_URL=

capture_run() {  # <stdout> <stderr> <command...>
  local stdout=$1 stderr=$2
  shift 2
  set +e
  "$@" >"$stdout" 2>"$stderr"
  RUN_RC=$?
  set -e
}

capture_pr_check() {  # <case_dir> <args...>
  local case_dir=$1
  shift
  capture_run "$case_dir/stdout" "$case_dir/stderr" run_pr_check "$case_dir" "$@"
}

capture_pr_check_quiet() {  # <case_dir> <args...>
  local case_dir=$1
  shift
  capture_run /dev/null "$case_dir/stderr" run_pr_check "$case_dir" "$@"
}

repeat_char() {  # <char> <count>
  local char=$1 count=$2 out=
  while [ "$count" -gt 0 ]; do out=$out$char; count=$((count - 1)); done
  printf '%s\n' "$out"
}

make_sha256sum_only_fakebin() {  # <case_dir> -> echoes fakebin dir
  local case_dir=$1 fakebin marker
  fakebin="$case_dir/portable-fakebin"
  marker="$case_dir/sha256sum-used"
  mkdir -p "$fakebin"
  for tool in dirname grep tail cut head tr cmp cp mkdir cat awk python3; do
    ln -sf "$(command -v "$tool")" "$fakebin/$tool"
  done
  cat > "$fakebin/sha256sum" <<EOF
#!/bin/sh
printf used > "$marker"
python3 - "\$1" <<'PY'
import hashlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
print(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}")
PY
EOF
  chmod +x "$fakebin/sha256sum"
  printf '%s\n' "$fakebin"
}

write_quality_learning_meta() {  # <case_dir> <base_sha> <digest>
  local case_dir=$1 base_sha=$2 digest=$3
  printf '%s\n' "quality_learning=active" >> "$case_dir/state/task-x1.meta"
  printf '%s\n' "quality_learning_base_sha=$base_sha" >> "$case_dir/state/task-x1.meta"
  printf '%s\n' "quality_learning_registry_digest=$digest" >> "$case_dir/state/task-x1.meta"
}

write_quality_learning_receipt() {  # <case_dir> <candidate_sha> <base_sha> <digest> <source_url>
  local case_dir=$1 candidate_sha=$2 base_sha=$3 digest=$4 source_url=$5
  cat > "$case_dir/data/task-x1/quality-learning-cloud-receipt.json" <<EOF
{
  "schema": "flowslate.codex_cloud_ci.v1",
  "candidate_sha": "$candidate_sha",
  "base_sha": "$base_sha",
  "checked_out_sha": "$candidate_sha",
  "status": "passed",
  "cleanup_status": "verified",
  "checks": [],
  "changed_files": [],
  "postgres": {
    "status": "not_started",
    "cleanup_status": "not_required"
  },
  "runtime": {},
  "quality_learning": {
    "candidate_sha": "$candidate_sha",
    "registry_base_sha": "$base_sha",
    "registry_digest": "$digest",
    "fact_source": "changed_files_only",
    "matched_lessons": [],
    "consult_doc_refs": [],
    "required_rules_evaluated": [],
    "advisory_rules_noted": [],
    "fingerprints": [],
    "waivers_applied": [],
    "expired_waivers": [],
    "ratchet_verdict": "not_evaluated",
    "status": "shadow",
    "runtime_ms": 1.25
  }
  }
EOF
  printf '%s\n' "$source_url" > "$case_dir/data/task-x1/quality-learning-cloud-receipt.source-url"
}

mutate_json_file() {  # <path> <python-expression>
  local path=$1 expr=$2
  python3 - "$path" "$expr" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expr = sys.argv[2]
document = json.loads(path.read_text(encoding="utf-8"))
namespace = {"document": document}
exec(expr, {}, namespace)
path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
}

setup_quality_learning_case() {  # <name> <candidate_sha> <base_sha> <digest> [source_url]
  QL_CASE_DIR=$(make_case "$1")
  QL_CANDIDATE_SHA=$2
  QL_BASE_SHA=$3
  QL_DIGEST=$4
  QL_SOURCE_URL=${5:-"https://example.invalid/receipts/$QL_CANDIDATE_SHA.json"}
  mkdir -p "$QL_CASE_DIR/wt"
  write_quality_learning_meta "$QL_CASE_DIR" "$QL_BASE_SHA" "$QL_DIGEST"
}

write_current_quality_learning_receipt() {
  write_quality_learning_receipt "$QL_CASE_DIR" "$QL_CANDIDATE_SHA" "$QL_BASE_SHA" "$QL_DIGEST" "$QL_SOURCE_URL"
}

add_current_quality_learning_mocks() {  # [head_sha]
  add_gh_mocks "$QL_CASE_DIR" "${1:-$QL_CANDIDATE_SHA}"
}

prime_current_quality_learning_receipt() {  # <pr_url> <failure_message>
  local pr_url=$1 failure_message=$2
  add_current_quality_learning_mocks
  write_current_quality_learning_receipt
  run_pr_check "$QL_CASE_DIR" task-x1 "$pr_url" >/dev/null || fail "$failure_message"
}

clear_current_quality_learning_intake() {
  rm -f "$QL_CASE_DIR/data/task-x1/quality-learning-cloud-receipt.json" \
    "$QL_CASE_DIR/data/task-x1/quality-learning-cloud-receipt.source-url"
}

mutate_current_quality_learning_receipt() {  # <python-expression>
  mutate_json_file "$QL_CASE_DIR/data/task-x1/quality-learning-cloud-receipt.json" "$1"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'no meta for task missing-x1' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_quality_learning_pr_check_refuses_missing_receipt() {
  setup_quality_learning_case quality-learning-missing-receipt aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$(repeat_char b 40)" "$(repeat_char d 64)"
  add_current_quality_learning_mocks

  capture_pr_check "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/31

  expect_code 1 "$RUN_RC" "quality-learning-missing-receipt: fm-pr-check should fail closed without receipt evidence"
  assert_grep 'exact-head Cloud receipt' "$QL_CASE_DIR/stderr" \
    "quality-learning-missing-receipt: refusal did not explain the missing receipt"
  assert_absent "$QL_CASE_DIR/state/task-x1.check.sh" \
    "quality-learning-missing-receipt: missing evidence must not arm a merge poll"
  pass "fm-pr-check refuses activated quality-learning tasks without receipt evidence"
}

test_quality_learning_pr_check_preserves_valid_receipt() {
  local copy meta_copy
  setup_quality_learning_case quality-learning-preserve aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$(repeat_char b 40)" "$(repeat_char d 64)"
  write_current_quality_learning_receipt
  add_current_quality_learning_mocks

  capture_pr_check "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/32

  expect_code 0 "$RUN_RC" "quality-learning-preserve: fm-pr-check should accept a valid exact-head receipt"
  grep -qxF 'pr=https://github.com/example/repo/pull/32' "$QL_CASE_DIR/state/task-x1.meta" \
    || fail "quality-learning-preserve: PR URL was not recorded after receipt validation"
  grep -qxF "pr_head=$QL_CANDIDATE_SHA" "$QL_CASE_DIR/state/task-x1.meta" \
    || fail "quality-learning-preserve: PR head was not recorded after receipt validation"
  copy="$QL_CASE_DIR/data/task-x1/quality-learning-receipts/$QL_CANDIDATE_SHA.json"
  meta_copy="$QL_CASE_DIR/data/task-x1/quality-learning-receipts/$QL_CANDIDATE_SHA.sha256"
  assert_present "$copy" "quality-learning-preserve: validated receipt copy was not preserved"
  assert_present "$meta_copy" "quality-learning-preserve: validated receipt hash metadata was not preserved"
  assert_grep "source_url=$QL_SOURCE_URL" "$meta_copy" \
    "quality-learning-preserve: preserved metadata lost the source url"
  assert_grep 'sha256=' "$meta_copy" \
    "quality-learning-preserve: preserved metadata lost the sha256"
  pass "fm-pr-check preserves a validated quality-learning receipt as immutable task-owned evidence"
}

test_quality_learning_pr_check_prefers_preserved_receipt_over_drifted_mutable_copy() {
  setup_quality_learning_case quality-learning-prefer-preserved abababababababababababababababababababab \
    "$(repeat_char b 40)" "$(repeat_char d 64)"
  prime_current_quality_learning_receipt https://github.com/example/repo/pull/321 \
    "quality-learning-prefer-preserved: initial receipt validation failed"

  write_quality_learning_receipt "$QL_CASE_DIR" "$QL_CANDIDATE_SHA" "$(repeat_char c 40)" "$QL_DIGEST" "$QL_SOURCE_URL"
  capture_pr_check "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/321

  expect_code 0 "$RUN_RC" "quality-learning-prefer-preserved: preserved receipt should win over drifted mutable intake"
  pass "fm-pr-check prefers preserved quality-learning evidence over a drifted mutable intake copy for the same PR head"
}

test_quality_learning_pr_check_reuses_preserved_receipt_only_for_same_head() {
  local new_head
  setup_quality_learning_case quality-learning-reuse bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    "$(repeat_char c 40)" "$(repeat_char e 64)"
  prime_current_quality_learning_receipt https://github.com/example/repo/pull/33 \
    "quality-learning-reuse: initial receipt validation failed"

  clear_current_quality_learning_intake
  # Reusing preserved evidence for the same head should stay green.
  run_pr_check "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/33 >/dev/null \
    || fail "quality-learning-reuse: preserved receipt should be reusable for the same PR head"

  new_head=cccccccccccccccccccccccccccccccccccccccc
  add_current_quality_learning_mocks "$new_head"
  capture_pr_check "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/33

  expect_code 1 "$RUN_RC" "quality-learning-reuse: fm-pr-check should fail closed when the fresh PR head drifts"
  assert_grep 'fresh PR head' "$QL_CASE_DIR/stderr" \
    "quality-learning-reuse: drift refusal did not explain the preserved-copy mismatch"
  pass "fm-pr-check reuses preserved quality-learning evidence only when the fresh PR head still matches"
}

test_quality_learning_pr_merge_reuses_preserved_receipt() {
  setup_quality_learning_case quality-learning-pr-merge dddddddddddddddddddddddddddddddddddddddd \
    "$(repeat_char e 40)" "$(repeat_char f 64)"
  : > "$QL_CASE_DIR/gh-axi.log"
  prime_current_quality_learning_receipt https://github.com/example/repo/pull/34 \
    "quality-learning-pr-merge: initial receipt validation failed"

  clear_current_quality_learning_intake
  run_pr_merge "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/34 \
    > "$QL_CASE_DIR/stdout" 2> "$QL_CASE_DIR/stderr" || fail "quality-learning-pr-merge: fm-pr-merge should reuse preserved evidence"

  grep -qxF 'pr merge 34 --repo example/repo --squash' "$QL_CASE_DIR/gh-axi.log" \
    || fail "quality-learning-pr-merge: merge did not proceed after preserved evidence reuse"
  pass "fm-pr-merge remains compatible with already-validated quality-learning evidence"
}

test_quality_learning_pr_check_rejects_tampered_preserved_receipt() {
  local preserved_copy
  setup_quality_learning_case quality-learning-tampered-preserved cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd \
    "$(repeat_char 6 40)" "$(repeat_char 7 64)"
  prime_current_quality_learning_receipt https://github.com/example/repo/pull/35 \
    "quality-learning-tampered-preserved: initial receipt validation failed"

  preserved_copy="$QL_CASE_DIR/data/task-x1/quality-learning-receipts/$QL_CANDIDATE_SHA.json"
  mutate_json_file "$preserved_copy" 'document["runtime"]["tampered"] = True'
  clear_current_quality_learning_intake
  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/35

  expect_code 1 "$RUN_RC" "quality-learning-tampered-preserved: tampered preserved receipt must fail closed"
  assert_grep 'preserved receipt metadata for '"$QL_CANDIDATE_SHA"' carries a sha256 that does not match the preserved receipt' "$QL_CASE_DIR/stderr" \
    "quality-learning-tampered-preserved: tampered preserved receipt was not rejected by sha256"
  pass "fm-pr-check rejects a tampered preserved quality-learning receipt copy"
}

test_quality_learning_pr_check_rejects_mismatched_preserved_sidecar() {
  local preserved_meta
  setup_quality_learning_case quality-learning-mismatched-preserved-sidecar dededededededededededededededededededede \
    "$(repeat_char 8 40)" "$(repeat_char 9 64)"
  prime_current_quality_learning_receipt https://github.com/example/repo/pull/36 \
    "quality-learning-mismatched-preserved-sidecar: initial receipt validation failed"

  preserved_meta="$QL_CASE_DIR/data/task-x1/quality-learning-receipts/$QL_CANDIDATE_SHA.sha256"
  cat > "$preserved_meta" <<EOF
sha256=$(repeat_char 0 64)
source_url=$QL_SOURCE_URL
EOF
  clear_current_quality_learning_intake
  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/36

  expect_code 1 "$RUN_RC" "quality-learning-mismatched-preserved-sidecar: mismatched preserved sha256 must fail closed"
  assert_grep 'preserved receipt metadata for '"$QL_CANDIDATE_SHA"' carries a sha256 that does not match the preserved receipt' "$QL_CASE_DIR/stderr" \
    "quality-learning-mismatched-preserved-sidecar: mismatched preserved sha256 was not rejected"
  pass "fm-pr-check rejects a preserved quality-learning sidecar whose sha256 no longer matches"
}

test_quality_learning_pr_check_rejects_non_https_preserved_source_url() {
  local preserved_meta
  setup_quality_learning_case quality-learning-non-https-preserved-source efefefefefefefefefefefefefefefefefefefef \
    "$(repeat_char a 40)" "$(repeat_char b 64)"
  prime_current_quality_learning_receipt https://github.com/example/repo/pull/37 \
    "quality-learning-non-https-preserved-source: initial receipt validation failed"

  preserved_meta="$QL_CASE_DIR/data/task-x1/quality-learning-receipts/$QL_CANDIDATE_SHA.sha256"
  cat > "$preserved_meta" <<EOF
$(cat "$preserved_meta")
source_url=http://example.invalid/receipts/$QL_CANDIDATE_SHA.json
EOF
  clear_current_quality_learning_intake
  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/37

  expect_code 1 "$RUN_RC" "quality-learning-non-https-preserved-source: non-https preserved source_url must fail closed"
  assert_grep 'preserved receipt metadata for '"$QL_CANDIDATE_SHA"' must use https://' "$QL_CASE_DIR/stderr" \
    "quality-learning-non-https-preserved-source: non-https preserved source_url was not rejected"
  pass "fm-pr-check requires an https preserved source_url before reusing quality-learning evidence"
}

test_quality_learning_pr_check_rejects_malformed_transport_fields() {
  local case_spec mutation scenario expected_error assertion_message
  local -a cases=(
    'document["quality_learning"].pop("ratchet_verdict")|quality-learning-malformed-transport-fields: missing ratchet_verdict must fail closed|quality_learning ratchet_verdict must be a non-empty string|missing ratchet_verdict was not rejected'
    'document["quality_learning"]["ratchet_verdict"] = ""|quality-learning-malformed-transport-fields: empty ratchet_verdict must fail closed|quality_learning ratchet_verdict must be a non-empty string|empty ratchet_verdict was not rejected'
    'document["quality_learning"]["waivers_applied"] = "waiver-1"|quality-learning-malformed-transport-fields: non-list waivers_applied must fail closed|quality_learning waivers_applied must be a list|waivers_applied was not rejected'
    'document["quality_learning"]["expired_waivers"] = "waiver-1"|quality-learning-malformed-transport-fields: non-list expired_waivers must fail closed|quality_learning expired_waivers must be a list|expired_waivers was not rejected'
    'document["quality_learning"]["runtime_ms"] = -1|quality-learning-malformed-transport-fields: negative runtime_ms must fail closed|quality_learning runtime_ms must be a nonnegative number|negative runtime_ms was not rejected'
  )

  setup_quality_learning_case quality-learning-malformed-transport-fields ababcdcdababcdcdababcdcdababcdcdababcdcd \
    "$(repeat_char c 40)" "$(repeat_char d 64)"
  add_current_quality_learning_mocks

  for case_spec in "${cases[@]}"; do
    IFS='|' read -r mutation scenario expected_error assertion_message <<EOF
$case_spec
EOF
    write_current_quality_learning_receipt
    mutate_current_quality_learning_receipt "$mutation"
    capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/43
    expect_code 1 "$RUN_RC" "$scenario"
    assert_grep "$expected_error" "$QL_CASE_DIR/stderr" \
      "quality-learning-malformed-transport-fields: $assertion_message"
  done

  pass "fm-pr-check rejects malformed quality-learning transport fields"
}

test_quality_learning_pr_check_accepts_policy_bearing_states() {
  setup_quality_learning_case quality-learning-policy-bearing-states edededededededededededededededededededed \
    "$(repeat_char f 40)" "$(repeat_char a 64)"
  add_current_quality_learning_mocks

  write_current_quality_learning_receipt
  mutate_current_quality_learning_receipt '
document["quality_learning"]["status"] = "required"
document["quality_learning"]["ratchet_verdict"] = "fail"
document["quality_learning"]["waivers_applied"] = ["waiver-1"]
document["quality_learning"]["expired_waivers"] = ["expired-1"]
document["quality_learning"]["runtime_ms"] = 0
'
  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/41
  expect_code 0 "$RUN_RC" "quality-learning-policy-bearing-states: policy-bearing values should be transported without firstmate policy decisions"
  pass "fm-pr-check accepts policy-bearing quality-learning states when identity and transport fields are valid"
}

test_quality_learning_pr_check_rejects_malformed_meta_registry_digest() {
  setup_quality_learning_case quality-learning-malformed-meta-digest cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd \
    "$(repeat_char 1 40)" "$(repeat_char A 64)"
  write_current_quality_learning_receipt
  add_current_quality_learning_mocks

  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/44

  expect_code 1 "$RUN_RC" "quality-learning-malformed-meta-digest: malformed metadata digest must fail closed"
  assert_grep 'quality_learning_registry_digest metadata to be exact 64-char lowercase hex' "$QL_CASE_DIR/stderr" \
    "quality-learning-malformed-meta-digest: malformed metadata digest was not rejected"
  pass "fm-pr-check rejects malformed quality-learning registry digest metadata"
}

test_quality_learning_pr_check_rejects_malformed_nested_registry_digest() {
  setup_quality_learning_case quality-learning-malformed-nested-digest dededededededededededededededededededede \
    "$(repeat_char 2 40)" "$(repeat_char a 64)"
  write_current_quality_learning_receipt
  mutate_current_quality_learning_receipt 'document["quality_learning"]["registry_digest"] = document["quality_learning"]["registry_digest"].upper()'
  add_current_quality_learning_mocks

  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/45

  expect_code 1 "$RUN_RC" "quality-learning-malformed-nested-digest: malformed nested digest must fail closed"
  assert_grep 'quality_learning registry_digest must be exact 64-char lowercase hex' "$QL_CASE_DIR/stderr" \
    "quality-learning-malformed-nested-digest: malformed nested digest was not rejected"
  pass "fm-pr-check rejects malformed nested quality-learning registry digests"
}

test_quality_learning_pr_check_requires_https_source_url() {
  setup_quality_learning_case quality-learning-https-source-url fefefefefefefefefefefefefefefefefefefefe \
    "$(repeat_char 1 40)" "$(repeat_char 2 64)" "http://example.invalid/receipt.json"
  write_current_quality_learning_receipt
  add_current_quality_learning_mocks

  capture_pr_check_quiet "$QL_CASE_DIR" task-x1 https://github.com/example/repo/pull/42

  expect_code 1 "$RUN_RC" "quality-learning-https-source-url: non-https source_url must fail closed"
  assert_grep 'quality-learning receipt source_url must use https://' "$QL_CASE_DIR/stderr" \
    "quality-learning-https-source-url: non-https source_url was not rejected"
  pass "fm-pr-check requires an https source_url for quality-learning receipt intake"
}

test_quality_learning_validate_falls_back_to_sha256sum_when_shasum_is_unavailable() {
  local fakebin rc
  setup_quality_learning_case quality-learning-sha256sum-fallback 1212121212121212121212121212121212121212 \
    "$(repeat_char 3 40)" "$(repeat_char 4 64)"
  write_current_quality_learning_receipt
  fakebin=$(make_sha256sum_only_fakebin "$QL_CASE_DIR")

  set +e
  PATH="$fakebin" FM_DATA_OVERRIDE="$QL_CASE_DIR/data" /bin/bash "$ROOT/bin/fm-quality-learning.sh" \
    validate task-x1 "$QL_CANDIDATE_SHA" "$QL_CASE_DIR/state/task-x1.meta" \
    >"$QL_CASE_DIR/stdout" 2>"$QL_CASE_DIR/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "quality-learning-sha256sum-fallback: helper should preserve via sha256sum fallback"
  assert_present "$QL_CASE_DIR/sha256sum-used" \
    "quality-learning-sha256sum-fallback: sha256sum fallback was not exercised"
  assert_present "$QL_CASE_DIR/data/task-x1/quality-learning-receipts/$QL_CANDIDATE_SHA.sha256" \
    "quality-learning-sha256sum-fallback: preserved sha256 metadata was not written"
  pass "fm-quality-learning.sh falls back to sha256sum when shasum is unavailable"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_quality_learning_pr_check_refuses_missing_receipt
test_quality_learning_pr_check_preserves_valid_receipt
test_quality_learning_pr_check_prefers_preserved_receipt_over_drifted_mutable_copy
test_quality_learning_pr_check_reuses_preserved_receipt_only_for_same_head
test_quality_learning_pr_merge_reuses_preserved_receipt
test_quality_learning_pr_check_rejects_tampered_preserved_receipt
test_quality_learning_pr_check_rejects_mismatched_preserved_sidecar
test_quality_learning_pr_check_rejects_non_https_preserved_source_url
test_quality_learning_pr_check_rejects_malformed_transport_fields
test_quality_learning_pr_check_accepts_policy_bearing_states
test_quality_learning_pr_check_rejects_malformed_meta_registry_digest
test_quality_learning_pr_check_rejects_malformed_nested_registry_digest
test_quality_learning_pr_check_requires_https_source_url
test_quality_learning_validate_falls_back_to_sha256sum_when_shasum_is_unavailable
