# 🩹 Scar Log — Regional Health On-Call Lab

One entry per incident. Written to be read in a hurry, at 2am, by the next
on-call engineer.

---

## OPS-2201 — Patient search collapsed under concurrent load; index alone wasn't the fix

- **S — Symptom:** Search by last name (`GET /api/patients/search`) was
  instant solo but under 200 concurrent shift-change users, p95 latency hit
  `11.11s` (baseline: `78.26ms`, a ~142× regression) with throughput dropping
  to `19.7 req/s` despite 4× the concurrent users.
- **C — Cause:** Two stacked mechanisms, not one. (1) No index on
  `last_name` forced a full table scan of all 100,000 rows per search
  (`EXPLAIN ANALYZE` confirmed `Table scan on patients, actual rows=100000`).
  (2) The query had no `LIMIT`, so every request returned all ~10,000
  matching rows (full columns, including an unbounded `notes TEXT` field) —
  serializing and transmitting that payload 200× concurrently was the actual
  bottleneck once the index made the DB-side query cheap.
- **A — Action:** Added `CREATE INDEX idx_patients_last_name ON
  patients(last_name);`, then bounded the query with `LIMIT 50` in
  `api/server.js` (matching the pattern already used by the healthy
  `/api/patients/recent` endpoint).
- **R — Result:** Index alone: query cost dropped 271ms → 59.5ms
  (uncontended), but 200-VU p95 stayed broken at `13.23s` — no real
  improvement. Index + LIMIT: p95 dropped to `132.22ms` (~84-100× better than
  broken, and only ~1.7× above the clean baseline of 78.26ms), throughput
  rose to `2407 req/s` (~105-122× better than broken).
- **Scar / lesson:** An index fixes query cost, not response cost. A cheap
  query that returns an unbounded, huge result set can still collapse a
  system under concurrency — the bottleneck moves from "DB scan time" to
  "serialize + transmit N rows × C concurrent callers." Always check *what
  volume of data* an endpoint returns, not just how the DB executes the
  query. A Grafana panel on response payload size / `data_received` rate per
  route, or a p95 threshold alert per endpoint, would have caught this before
  a ticket was filed — the ~3GB `data_received` under load was visible in k6
  output the whole time, it just wasn't looked at until the index "fix"
  didn't work.
- **Evidence:** [LAB_JOURNAL.md — Investigation OPS-2201](./LAB_JOURNAL.md#investigation--ops-2201),
  [evidence/baseline/Screenshot 2026-08-09 at 17.58.18.png](./evidence/baseline/Screenshot%202026-08-09%20at%2017.58.18.png),
  fix commit in `api/server.js` (`/api/patients/search` route).
