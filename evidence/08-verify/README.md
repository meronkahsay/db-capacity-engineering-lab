# C8 — `make verify`

**Status:** ⏳ not started — no infra dependency for writing the script
itself, but a full green run needs the live apply.

`make verify` (repo root `Makefile`, target `verify`) should, in one command,
re-check everything gradable without a human re-deriving it by hand:

- `tflocal plan` shows no diff against the applied state (C1).
- `/healthz` and `/readyz` both return the expected codes (C3/C4).
- The three CI gates (gitleaks/trivy/zizmor) pass locally via their CLIs,
  matching what CI enforces (C5).
- Alert rules file is valid Prometheus syntax (`promtool check rules`) (C6).

Exits non-zero on any failure, so it's a real gate a grader (or CI) can run,
not just a checklist.
