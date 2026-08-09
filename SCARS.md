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

---

## OPS-2202 — Registration surge collapsed the app while the DB stayed idle; two stacked bottlenecks

- **S — Symptom:** Under a sudden burst to 2000 concurrent users hitting the
  trivial, indexed `GET /api/patients/recent`, p95 latency hit `3.38s`
  (baseline: `78.26ms`, ~43× regression) while `docker stats` showed
  **mysql-db at 0.83% CPU and capacity-api at 0.66% CPU** — both essentially
  idle. "The DB is bored" (per the ticket) was independently confirmed, not
  just trusted.
- **C — Cause:** `connectionLimit: 2` in `api/database.js` — the app's MySQL
  connection pool, not the database or the query, was the bottleneck. Only 2
  requests could ever be executing a query at once; the other ~1998 queued
  inside the app tier waiting for a free connection (`queueLimit: 0` =
  unbounded queue, explaining 0% errors + huge latency instead of fast
  rejections). Little's Law confirmed it: measured service time W=1.73ms
  (`EXPLAIN ANALYZE`, uncontended) x measured arrival rate λ=1620 req/s ≈ 2.8
  connections needed just for steady-state average demand — already above
  the configured limit of 2. Theoretical max throughput of a pool of 2
  (2/W ≈ 1156 req/s) was itself below the 1620 req/s of arrivals, so
  queueing was mathematically guaranteed.
- **A — Action:** Two changes, both required. (1) Raised `connectionLimit`
  (and `maxIdle`) from 2 to 20 in `api/database.js` — sized at ~7× the
  calculated steady-state need for burst headroom, well under MySQL's own
  `max_connections=151`. (2) Reduced `/api/patients/recent`'s query from
  `LIMIT 50` to `LIMIT 10` in `api/server.js` after step 1 alone exposed a
  second bottleneck (see Result) — direct testing showed each `LIMIT 50`
  response was 18,145 bytes; at 2000 concurrent requests that's ~36MB of
  JSON being synchronously serialized on Node's single JS thread,
  blocking the event loop.
- **R — Result:** Step 1 alone: p95 improved 3.38s → 2.63s (~22%), but
  `docker stats` mid-run showed capacity-api CPU spike to **173%** and
  memory climb to 120/160MiB (75%), with a *new* 0.37% error rate
  (`connection reset by peer`) appearing — a regression in kind, not
  degree. Step 1+2 together, confirmed across two separate reproduction
  runs: p95 **1.25-1.52s**, throughput **~2722-2780 req/s** (vs. broken
  1620 req/s), error rate **0.00%** (threshold now passes cleanly), and
  live `docker stats` mid-run showed CPU back down to **0.83%** — directly
  confirming payload size, not just connection count, was driving the CPU
  spike.
- **Scar / lesson:** Fixing one finite resource (the connection pool) just
  moved the bottleneck to the next one (application-tier CPU/event-loop
  time spent on synchronous JSON serialization) — it did not eliminate
  contention on the first pass, it relocated it, and initially made it
  manifest as hard connection resets instead of pure queueing latency.
  "The DB looks idle" is a real, verifiable, and *misleading* signal if you
  stop looking there — the true bottleneck can be one layer up in the
  stack, and a single fix should be re-verified under the *same* load
  before declaring victory, not just checked for "did it get better."  A
  per-route CPU/event-loop-lag panel in Grafana, or an alert on sustained
  container CPU >100%, would have caught this before a ticket was filed.
  Trade-off: the "recent patients" widget now shows 10 patients instead of
  50 — a real, visible cost, not a free win; production would want
  pagination or a lighter column set instead of a permanently smaller page.
- **Evidence:** [LAB_JOURNAL.md — Investigation OPS-2202](./LAB_JOURNAL.md#investigation--ops-2202),
  fix commits in `api/database.js` (`MYSQL_CONFIG.connectionLimit`) and
  `api/server.js` (`/api/patients/recent` route).
