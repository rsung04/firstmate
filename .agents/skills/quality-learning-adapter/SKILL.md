---
name: quality-learning-adapter
description: Agent-only reference for firstmate's thin provider-neutral quality-learning spawn and acceptance adapter. Use when a ship or scout task worktree contains docs/workflows/quality-learning-harness.md and scripts/ci/check-quality-learning.py, or when a task's meta records quality_learning=active during PR readiness or merge.
user-invocable: false
metadata:
  internal: true
---

# quality-learning-adapter

Load this when a ship or scout task's worktree contains both `docs/workflows/quality-learning-harness.md` and `scripts/ci/check-quality-learning.py`, or when a task's meta records `quality_learning=active` during PR readiness, acceptance, or merge.

The adapter is transport only.
It must not copy the registry, interpret product lessons, create a new store, calculate a score, or implement a provider-specific evaluator.

## Spawn contract

Activation is gated only by the repository-owned files above.
Legacy projects with either file absent stay byte-compatible.

For an activated task:

1. Compute the exact task worktree `HEAD`.
2. Run the repository context-only command from that worktree:

```bash
python3 scripts/ci/check-quality-learning.py \
  --mode context-only \
  --base-sha <exact-base-sha>
```

3. Use that response only to bind `base_sha` and `registry_digest`.
4. Inject or refresh one marker-bounded brief section that tells the worker to rerun the same command before implementation with intended `--path` and `--risk-flag` values, read every returned `owning_doc_refs` entry, and recompute the context when scope changes materially.
5. Record only the minimal activation metadata in task meta: `quality_learning=active`, `quality_learning_base_sha=<sha>`, and `quality_learning_registry_digest=<sha256>`.

The worker owns path and risk selection.
Firstmate must not infer lessons from the task text.

## Acceptance contract

An activated task is not PR-ready unless it has a readable exact-head Cloud receipt and a source URL.
The task-owned intake paths are:

- `data/<id>/quality-learning-cloud-receipt.json`
- `data/<id>/quality-learning-cloud-receipt.source-url`

Validate only the existing additive `quality_learning` object on the existing `flowslate.codex_cloud_ci.v1` receipt.
Require:

- outer `schema=flowslate.codex_cloud_ci.v1`
- outer `candidate_sha`, `checked_out_sha`, and fresh PR head to match exactly
- outer `base_sha` to match `quality_learning_base_sha`
- outer `status=passed`
- outer `cleanup_status=verified`
- meta `quality_learning_registry_digest` to be exact 64-char lowercase hex
- nested `quality_learning.candidate_sha` to match the fresh PR head
- nested `quality_learning.registry_base_sha` to match `quality_learning_base_sha`
- nested `quality_learning.registry_digest` to be exact 64-char lowercase hex and match `quality_learning_registry_digest`
- nested `quality_learning.fact_source=changed_files_only`
- nested `quality_learning.status` must be exactly one of `shadow`, `advisory`, or `required`
- nested `quality_learning.ratchet_verdict` to be a non-empty string
- nested `quality_learning.waivers_applied` and `quality_learning.expired_waivers` to be lists
- nested `quality_learning.runtime_ms` to be a nonnegative number

Firstmate stays transport only.
It records those values as receipt evidence and does not reject `ratchet_verdict=fail`, non-empty `expired_waivers`, or `status=required` with a non-pass verdict when the transport shape and identity checks are valid.
Reject absent, stale, malformed, mismatched, or candidate-mismatched evidence.

On first acceptance, preserve the receipt as immutable task-owned evidence:

- `data/<id>/quality-learning-receipts/<candidate-sha>.json`
- `data/<id>/quality-learning-receipts/<candidate-sha>.sha256`

The sidecar stores the SHA-256 and `source_url`.
Later checks may reuse only that preserved copy, and only when the fresh PR head still matches the preserved candidate SHA.
Any head drift fails closed.
`fm-pr-merge` stays compatible by reusing the same validated preserved copy through `fm-pr-check`.

## Recurring-signal routing

Qualified recurring signals become one candidate on the existing issue or task for a human-approved registry PR.
Do not auto-write the registry.
Do not create a second store, proposal DB, score, or scheduler.
