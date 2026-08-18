---
name: quality-learning-brief
description: Agent-only reference for adding repository-owned quality context to an applicable coding brief.
user-invocable: false
metadata:
  internal: true
---

# quality-learning-brief

Load this before finalizing a coding or regression-repair brief for a project that contains both `docs/workflows/quality-learning-harness.md` and `scripts/ci/check-quality-learning.py`.
If either file is absent, leave the brief unchanged.

Add one short section to the brief:

```text
## Repository quality context

Before modifying code, run:

python3 scripts/ci/check-quality-learning.py \
  --mode context-only \
  --base-sha <exact-base-sha> \
  --path <intended-path>

Read every returned owning-document reference and record the matched lesson IDs and registry digest in the task report.
Repeat `--path` for each intended area and rerun the command when the changed-file scope materially changes.
The repository's existing exact-head verification remains the authority for the resulting candidate.
```

Resolve `<exact-base-sha>` from the verified project base used to create the task worktree.
Keep path scope bounded to the task's intended files or areas.
Do not execute the command yourself, interpret lesson policy, copy the registry, create evidence storage, or change merge behavior.
The worker owns context resolution and follows the repository's returned references.
