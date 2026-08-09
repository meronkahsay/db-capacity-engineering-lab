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

---

## OPS-2203 — Bed admissions serialized on one hospital's row lock; ~200x throughput recovered, one architectural ceiling remains

- **S — Symptom:** 500 concurrent admissions to the *same* hospital
  (`POST /api/hospitals/1/admit`) produced p95=`56.72-57.14s` (baseline:
  `78.26ms`, ~730× regression) and a **46.04% error rate** — the first
  incident with real, high-volume database errors rather than pure latency.
  Different hospitals were unaffected; one-at-a-time admits were fine —
  matching the ticket exactly.
- **C — Cause:** `POST /api/hospitals/:id/admit` ran `BEGIN -> UPDATE
  hospitals SET available_beds = available_beds - 1 -> await
  notifyBedRegistry() [500ms simulated network call] -> COMMIT`. The
  `UPDATE`'s row lock (required for isolation — without it, concurrent
  admits could race and lose a decrement) was held for the *entire* 500ms
  external call, not just the sub-ms database write. A live join of
  `performance_schema.data_lock_waits` to `information_schema.innodb_trx`
  captured a 171-row single-file lock-wait chain, every query text
  identical, all contending for hospital `id=1`'s row. `SHOW GLOBAL STATUS
  LIKE 'Innodb_row_lock%'` showed average wait ~4992ms — right at the
  configured `innodb-lock-wait-timeout=5s` — directly explaining why ~46%
  of waiters timed out rather than just running slow. Capacity math: with
  critical section W≈0.5s, theoretical max throughput for one hospital row
  = 1/W ≈ 2 admits/sec, a hard ceiling regardless of concurrency —
  consistent with the measured 3.58 req/s.
- **A — Action:** Reordered to commit immediately after the (now
  guarded) `UPDATE`, moving `notifyBedRegistry` to fire *after* commit,
  outside the transaction. Also added `AND available_beds > 0` to the
  `UPDATE` plus a `409 NO_BEDS_AVAILABLE` response — a separate
  correctness fix for a floor-check gap noticed while reading the code
  (the original query could drive beds negative under concurrency).
  Raised `connectionLimit` 20→50 after confirming the pool was saturated
  (`Max_used_connections`≈22) under 500 VUs.
- **R — Result:** p95 dropped 56.72-57.14s → **1.06-1.13s** (~51×), errors
  46.04% → **0.00%**, throughput 3.58 → **~700-720 req/s** (~200×). The
  pool increase (20→50) was tested and barely moved p95 (1.11s→1.06s),
  directly proving pool size was *not* the dominant remaining cost.
  `Innodb_row_lock_time_avg` dropped to **117ms** (from ~4992ms, a ~43×
  reduction), confirming the critical section is now genuinely short. The
  k6 script's `p(95)<1000ms` threshold still narrowly fails (~1.06-1.13s)
  — investigated, not hand-waved: this is the measured, reproducible cost
  of 500 concurrent writers safely serializing onto **one** row, an
  architectural ceiling (only one transaction can hold a given row's lock
  at a time) that no further pool or code tuning removes.
- **Scar / lesson:** Never hold a lock across an external network call —
  find the minimum work that must happen *inside* the transaction (the
  write itself) and move everything else outside it, even if that changes
  when downstream systems get notified (a real consistency trade-off,
  named honestly rather than hidden: the registry can now be briefly
  behind committed state, or its notification can fail independently of
  the admission). Also: not every miss is a bug — some latency floors are
  architectural (single-row serialization) and the honest move is to prove
  that with numbers (pool-size test, lock-wait-time measurement) rather
  than either quietly ship a failing threshold or keep chasing a fix that
  the math says won't work. A per-hospital admit-throughput panel, or an
  alert on `Innodb_row_lock_time_avg` crossing a fraction of
  `innodb-lock-wait-timeout`, would have caught this building before a
  ticket was filed.
- **Evidence:** [LAB_JOURNAL.md — Investigation OPS-2203](./LAB_JOURNAL.md#investigation--ops-2203),
  fix commits in `api/server.js` (`/api/hospitals/:id/admit` route) and
  `api/database.js` (`MYSQL_CONFIG.connectionLimit`).

---

## OPS-2204 — Nightly export crash-looped the whole service; streaming alone wasn't enough

- **S — Symptom:** 50 concurrent callers of `GET /api/patients/export`
  (unbounded `SELECT * FROM patients`, ~100,000 rows, no `LIMIT`) produced
  a **100.00% error rate** (111,893/111,893 failed) and **13 container
  restarts** in a 2-minute run — total service outage, the worst incident
  in the lab. `docker stats` caught the container at 159.1/160MiB (99.44%)
  moments before a crash.
- **C — Cause:** the export buffered the entire result set into memory
  (one giant array of ~100,000 JS objects, then one `JSON.stringify` call)
  before sending anything. The hypothesis (a silent kernel OOM-kill from
  the `NODE_OPTIONS: --max-old-space-size=256` vs `mem_limit: 160m`
  mismatch) was **partially disproven by evidence** — `docker inspect`
  showed `OOMKilled: false`; the actual crash log was a V8-internal
  `FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out
  of memory`, with heap sitting at 253.5-259.6MB (right at V8's own 256MB
  ceiling) and two consecutive full GCs (1.4s, 1.7s) reclaiming almost
  nothing before V8 self-terminated. The 160MB container cap was still
  directly implicated (99.44% real memory use at the same moment) — the
  underlying cause (O(N) memory scaling with table size) was unchanged
  either way; only the specific trigger differed from the hypothesis.
- **A — Action:** two changes, in sequence. (1) Replaced the buffered query
  with `mysql2`'s row-by-row `.stream()`, writing newline-delimited JSON as
  rows arrived instead of materializing the full result set. (2) After
  streaming alone proved insufficient (see Result), added cursor-based
  pagination (`LIMIT 2000` + `WHERE id > ?` on the indexed primary key,
  `?after=` param, `X-Next-After`/`X-Has-More` response trailers).
- **R — Result:** Streaming alone: **restarts eliminated (13→0)**, memory
  stayed flat at 50.11MiB/160MiB (31%) — but a *new* failure mode appeared:
  14.78% `request timeout` errors and p95=1m50s, traced to `data_received`
  of 4.4GB across 115 requests (~38MB/request) — streaming fixed memory,
  not total bytes transferred, and 50 concurrent full-table streams
  saturated bandwidth/CPU. Streaming + pagination together: **0.00% errors**
  (0/14,305), p95=**611.87ms**, throughput 0.75→**118.82 req/s**, restarts
  still 0. A real bug was found and fixed along the way: the first
  pagination attempt set response headers in the stream's `'end'` handler,
  but Node flushes headers on the first `res.write()` — silently dropped
  until switched to HTTP trailers (`res.addTrailers`), verified via `curl -D -`.
- **Scar / lesson:** Fixing memory (streaming) does not automatically fix
  capacity — total data volume is its own resource, separate from how
  carefully you hold it in RAM. An unbounded result set is unsafe at any
  concurrency no matter how cleverly you stream it; the durable fix is
  always to bound *how much* is returned per call, not just *how*. Also: a
  plausible-sounding root cause (kernel OOM-kill) can be subtly wrong even
  when the broader diagnosis (memory scaling with table size) is right —
  `docker inspect`'s `OOMKilled` field and the actual crash log are the
  ground truth, not the first theory that fits the symptoms. A per-route
  `data_received`/bandwidth panel in Grafana, or an alert on
  `nodejs_heap_size_used_bytes` approaching `--max-old-space-size`, would
  have caught this building before a ticket was filed.
- **Evidence:** [LAB_JOURNAL.md — Investigation OPS-2204](./LAB_JOURNAL.md#investigation--ops-2204),
  fix commit in `api/server.js` (`/api/patients/export` route).
