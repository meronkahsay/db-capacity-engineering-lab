# C6 — Alert rules + dashboard

**Status:** ⏳ not started.

Four alert rules, one per A1 incident, added to `monitoring/` (Prometheus
alert rules + Grafana dashboard panels reused/extended from A1's board).

| Incident | Alert | Signal |
|---|---|---|
| OPS-2201 (search collapse) | `HighSearchLatencyP95` | p95 latency on the search endpoint over threshold |
| OPS-2202 (registration surge) | `RegistrationQueueSaturation` | connection-pool queueing / request rate vs. capacity |
| OPS-2203 (admission lock contention) | `AdmissionLockWaitHigh` | `data_locks`/lock-wait time on the admissions table |
| OPS-2204 (export OOM) | `ExportMemoryNearLimit` | container memory vs. `--memory` limit approaching 100% |

## What goes here

- `alert-rules.yml` (or a diff against `monitoring/`'s existing Prometheus
  rules file) with the four rules above, each with a real `expr`, `for`, and
  `severity` label.
- Grafana screenshot(s) showing the panels/rules loaded.
- Per the brief's reduced scope note: one incident gets the "full treatment"
  (alert fires → dashboard screenshot → mechanism named in the panel/alert
  description); the other three can be alert-only.
