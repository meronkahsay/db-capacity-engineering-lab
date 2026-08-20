# C7 — Incident replay against the deployed stack

**Status:** ⏳ blocked on a live apply (see [../01-iac](../01-iac)) and on
[../06-alerts](../06-alerts) alert rules being loaded.

Re-run each of the 4 A1 k6 scripts (`load-tests/reproduce-OPS-22XX.js`)
against the LocalStack-deployed instance (not the local docker-compose
stack A1 used), and prove:

1. The fault reproduces (same symptom as A1, evidenced fresh here).
2. The corresponding alert (see 06-alerts) fires.
3. The A1 fix (already committed to this repo) still holds — re-run after
   confirming the alert cleared.

Per the brief's reduced scope for this follow-up: pick **one** incident for
the full treatment (fire → dashboard screenshot → name the mechanism again
in this new environment); the other three just need "reproduced + alert
fired + fix holds" evidence, no need to re-derive the full root-cause
analysis (that's already in `LAB_JOURNAL.md`/`SCARS.md`).

## What goes here

- `<incident>/k6-summary.txt`, `<incident>/alert-firing.png`,
  `<incident>/alert-cleared.png` per incident replayed.
