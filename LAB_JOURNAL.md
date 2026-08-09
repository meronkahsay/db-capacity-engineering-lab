# 🧾 On-Call Lab Journal — Regional Health

**Engineer:** Meron Kahsay  **Date:** 2026-08-09

This is your investigation notebook. You are on call for the Regional Health
platform and working the [incident queue](./incidents/README.md). For each
incident you will:

1. **Hypothesis** — from the ticket symptoms alone, predict the cause *before*
   you run anything.
2. **Observation** — record real evidence: k6 output, Grafana/Prometheus
   metrics, `EXPLAIN ANALYZE` plans, lock views, `docker stats`, container logs.
3. **Root cause & mechanism** — explain *why* it happens. Name the database/OS
   mechanic yourself and show the capacity math.
4. **Fix & verify** — make the change, re-run the reproduction, and record the
   before/after.

> There is no answer key. A claim without evidence isn't a diagnosis. "It felt
> slow" is not an observation; `p(95)=1840ms, http_req_failed=32%` is.

---

## How to capture evidence

- **k6:** copy the summary block (`http_req_duration`, `http_req_failed`,
  `iterations`, `vus`).
- **MySQL:** `docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab`
  then run `EXPLAIN ANALYZE ...`, `SHOW CREATE TABLE ...`,
  `SHOW ENGINE INNODB STATUS\G`, or query `performance_schema` / `sys`.
- **Metrics:** Grafana panels or raw Prometheus at http://localhost:9090.
- **Memory / restarts:** `docker stats`, `docker compose logs -f capacity-api`.

Useful Prometheus queries:
```promql
# Throughput (req/s) by route
sum(rate(http_requests_total[1m])) by (route)

# p95 latency by route
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, route))

# Application heap in use
nodejs_heap_size_used_bytes

# DB errors by code
sum(rate(db_errors_total[1m])) by (code)
```

---

## Baseline — steady state (do this first)
*Run:* `k6 run load-tests/00-baseline.js` (healthy system, no incident)

Capture the control group you'll compare every incident against.

| Metric              | Value |
|---------------------|-------|
| Requests/sec (RPS)  | 48.84 req/s |
| p50 latency         | 12.01 ms (median) |
| p95 latency         | 78.26 ms |
| p99 latency         | 118.66 ms |
| Error rate          | 0.00% (0/1500) |
| Peak API heap used  | ~20 MB (Grafana "API memory vs container limit" panel, blue `heap used` line; RSS ~65-100MB, container limit not yet reached) |

Raw k6 summary (`k6 run --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" load-tests/00-baseline.js`):
```
  █ THRESHOLDS

    http_req_duration
    ✓ 'p(95)<200' p(95)=78.26ms

    http_req_failed
    ✓ 'rate<0.01' rate=0.00%

  █ TOTAL RESULTS

    checks_total.......: 1500    48.836425/s
    checks_succeeded...: 100.00% 1500 out of 1500
    checks_failed......: 0.00%   0 out of 1500

    HTTP
    http_req_duration..............: avg=22.18ms min=620µs med=12.01ms p(90)=66.84ms p(95)=78.26ms p(99)=118.66ms max=131.96ms
    http_req_failed................: 0.00%  0 out of 1500
    http_reqs......................: 1500   48.836425/s

    EXECUTION
    iteration_duration.............: avg=1.02s   min=1s    med=1.01s   p(90)=1.06s   p(95)=1.08s   p(99)=1.11s    max=1.13s
    iterations.....................: 1500   48.836425/s
    vus............................: 50     min=50        max=50
    vus_max........................: 50     min=50        max=50

running (0m30.7s), 00/50 VUs, 1500 complete and 0 interrupted iterations
```

> Note: an earlier baseline run (without `--summary-trend-stats`) showed p95=69.25ms — the ~9ms difference vs. this run's p95=78.26ms is normal run-to-run variance (background load, container warm-up), not a system change. Treat baseline comparisons at the order-of-magnitude level, not single-digit-ms precision.

> SLOs you'll hold the incidents to (target p95, max error rate, RPS floor):
> Target p95 ≤ 200ms (matches the k6 script's built-in threshold), error rate < 1%, RPS floor ≥ 45 req/s (baseline sustained ~48.8 req/s at 50 VUs with zero errors — any incident that drops meaningfully below this or breaches p95/error thresholds is a regression, not "normal variance").

**Grafana evidence:** [evidence/baseline/Screenshot 2026-08-09 at 17.58.18.png](../evidence/baseline/Screenshot%202026-08-09%20at%2017.58.18.png) — "Capacity Lab — Regional Health" dashboard during the baseline k6 run (17:53-17:55 window): throughput spikes to ~30 req/s, p95 latency spikes to ~65ms (agrees with k6's own p95=69.25ms), heap used stays flat at ~20MB, zero DB errors.

---

## Investigation — OPS-2201
*Ticket:* [Patient name search unusably slow at shift change](./incidents/OPS-2201.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2201.js`

### Hypothesis
> From the symptoms alone (fast when isolated, collapses under concurrent
> searches, other endpoints unaffected), I think the cause is
> a full table scan on `patients.lastName` because there is no index on that
> column, so every search request forces MySQL/InnoDB to read all ~100,000 rows
> and check each one for a match
> because a single scan is cheap enough to feel instant (tens of ms), but many
> concurrent scans over the same 100k-row table compete for the same CPU and
> buffer-pool/disk I/O, so per-request cost stays roughly fixed while total
> system load scales with concurrent users — collapsing throughput at shift
> change. The sibling "recent patients" endpoint likely stays fast because it's
> either indexed or returns a small, fixed-size result set, so its cost doesn't
> scale with table size or concurrency the same way.

### Observation (evidence)
> Investigate how the database executes the search. Paste what you find:
> ```
> mysql> SHOW CREATE TABLE patients;
> CREATE TABLE `patients` (
>   `id` int NOT NULL AUTO_INCREMENT,
>   `first_name` varchar(64) NOT NULL,
>   `last_name` varchar(64) NOT NULL,
>   `email` varchar(128) NOT NULL,
>   `diagnosis` varchar(255) NOT NULL,
>   `notes` text NOT NULL,
>   `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
>   PRIMARY KEY (`id`)
> ) ENGINE=InnoDB AUTO_INCREMENT=131071 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
> -- Only key is PRIMARY KEY (id). No index on last_name.
>
> mysql> EXPLAIN ANALYZE SELECT * FROM patients WHERE last_name = 'Smith';
> -> Filter: (patients.last_name = 'Smith')  (cost=10276 rows=9819) (actual time=2.8..271 rows=10000 loops=1)
>     -> Table scan on patients  (cost=10276 rows=98191) (actual time=1.09..265 rows=100000 loops=1)
> ```
> k6 reproduction (`k6 run load-tests/reproduce-OPS-2201.js`, 200 VUs, 30s):
> ```
> ✗ 'p(95)<300' p(95)=11.11s
> http_req_duration..............: avg=8.96s min=513.99ms med=9.61s max=11.6s p(90)=10.59s p(95)=11.11s
> http_req_failed................: 0.00%  0 out of 794
> http_reqs......................: 794    19.709111/s
> data_received..................: 2.9 GB 72 MB/s
> ```

| Metric (under load) | Value | vs. baseline |
|---------------------|-------|--------------|
| p95 latency         | 11.11 s | ~142× worse (baseline p95 = 78.26ms) |
| RPS                 | 19.71 req/s | lower than baseline's 48.84 req/s, despite 4× the VUs (200 vs 50) |
| Error rate          | 0.00% (0/794) | same as baseline — every request eventually returned 200, but took up to 11.6s. Ticket says "sometimes it errors out"; evidence shows no HTTP errors, just extreme latency a nurse would reasonably describe as "erroring out" |
| Rows examined / req | 100,000 (full table scan, `EXPLAIN ANALYZE`) | baseline endpoint presumably examines far fewer rows (not yet measured directly) |

### Root cause & mechanism
> What is the database doing per request, and why does cost blow up with data
> size and concurrency? Name the mechanism and the data structure involved.
> Estimate the cost difference between the current behaviour and the ideal one
> for ~100,000 rows.
>
> **Mechanism: full table scan due to a missing index on `last_name`.**
> `patients` has only a `PRIMARY KEY (id)` — a B-tree index on `id` — and no
> index on `last_name`. Without an index, MySQL/InnoDB has no data structure
> that lets it jump directly to rows matching `last_name = 'Smith'`. Its only
> option is a table scan: read every row in primary-key order off disk/buffer
> pool and check each one against the filter. `EXPLAIN ANALYZE` confirms this
> exactly — `Table scan on patients (actual rows=100000)` followed by a
> `Filter` step that examines all 100,000 rows to find the 10,000 matches.
>
> A single scan costs ~265-271ms of real DB-side work (measured, uncontended).
> That's tolerable for one user but is **CPU/memory-bound work inside MySQL**
> that competes for the same finite buffer pool and CPU threads as every other
> concurrent query. It does not parallelize for free: with a much smaller
> number of usable execution threads than 200 concurrent callers, requests
> queue behind each other. This is basic queueing behavior (Little's Law
> territory, formalized in OPS-2202) — as concurrent scan requests pile up
> faster than the DB can retire them, wait time per request balloons well
> beyond the ~270ms base cost. That's exactly what we measured: p95 jumped
> from baseline's 78ms to 11.11s (~142×) under 200 concurrent VUs, while
> throughput *dropped* to 19.7 req/s despite 4× the concurrent users — a
> classic sign of contention overwhelming a fixed-cost-per-op resource, not a
> system that scales with load.
>
> **Cost estimate, current vs. ideal:** current behaviour examines all
> ~100,000 rows per search regardless of how many match (full table scan is
> O(N) in table size). An index on `last_name` (a B-tree) would let MySQL
> seek directly to the ~10,000 matching rows for "Smith" in roughly
> O(log N + matches) — i.e., a handful of B-tree page reads to locate the
> start of the "Smith" range, then a sequential read of only the matching
> rows, instead of reading and filtering all 100,000. That's roughly a
> 10-20× reduction in rows touched for a common surname, and a far larger
> reduction for a rare surname (same O(log N) seek cost, but far fewer rows
> returned) — full scans pay the same 100,000-row cost no matter how
> selective the search is, which is itself a property of the missing index,
> not the search logic.

### Fix & verify
> The change you made (be specific):
> Two changes, applied in sequence — evidence showed the first alone was
> insufficient:
> 1. `CREATE INDEX idx_patients_last_name ON patients(last_name);` — gives
>    MySQL a B-tree to seek into instead of scanning all 100,000 rows.
> 2. `api/server.js`, `/api/patients/search` route: changed
>    `SELECT * FROM patients WHERE last_name = ?` to
>    `SELECT * FROM patients WHERE last_name = ? LIMIT 50` — bounds the result
>    set the same way the already-fast `/api/patients/recent` endpoint does
>    (`LIMIT 50`), instead of returning all ~10,000 matching rows per request.
>
> **Why the index alone wasn't enough (a real "obvious fix doesn't work"
> moment):** after adding only the index, `EXPLAIN ANALYZE` confirmed the
> per-query DB cost dropped from ~271ms (table scan) to ~59.5ms (index
> lookup) — a real 4.5× improvement, uncontended. But re-running the 200-VU
> reproduction still gave p95=13.23s, no better than the unindexed baseline
> (p95=11.11s). Evidence pointed at the real bottleneck: the query had no
> `LIMIT`, so every request returned all ~10,000 matching rows (full columns,
> including an unbounded `notes TEXT` field) — serializing and transmitting
> that payload 200 times concurrently is what was actually collapsing the
> system, not database query cost. `data_received` stayed ~3GB across both
> "broken" runs, confirming the response size — not the query plan — was the
> unaddressed cost.
>
> Re-run evidence — new query behaviour: `curl` against the live endpoint
> after the fix confirms `count: 50, rows returned: 50` (was ~10,000 before).
>
> k6 reproduction, before (index only) vs after (index + LIMIT):
> ```
> BEFORE (index only):  p95=13.23s   RPS=22.92/s    requests=887    data=3.2GB
> AFTER  (index+LIMIT):  p95=132.22ms RPS=2407.15/s  requests=72403  data=1.3GB
> ```
> New p95: **132.22ms** (vs. broken 11.11-13.23s; vs. own baseline 78.26ms)
> New RPS: **2407.15 req/s** (vs. broken ~20-23 req/s; vs. own baseline
> 48.84 req/s)
> Improvement factor: **~84-100× on p95, ~105-122× on throughput** vs. the
> broken state (index-only fix). Threshold `p(95)<300ms` now passes (was
> failing by ~40×).
>
> Any trade-off introduced by your fix? Search now returns only the first 50
> matches (ordered however InnoDB returns them, not explicitly ranked) instead
> of all matches — for a common surname like "Smith" (~10,000 matches) a nurse
> would only see a subset unless the endpoint later adds real pagination
> (`OFFSET`/cursor + a "next page" control). For this lab's purposes bounding
> the result set is the correct capacity fix; a production version would need
> pagination so the other ~9,950 "Smith" records are still reachable. The
> index itself adds minor write-side overhead (B-tree maintenance on every
> INSERT/UPDATE to `last_name`) and disk space — negligible at this write
> volume, worth stating rather than ignoring.

---

## Investigation — OPS-2202
*Ticket:* [Whole app freezes during surges, DB looks idle](./incidents/OPS-2202.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2202.js`

### Hypothesis
> Given the query is trivial and the DB is idle yet requests pile up, I think
> the bottleneck is the application's MySQL connection pool — a small, fixed
> number of reusable connections between the Node app and MySQL
> because a query cannot execute until a request first acquires a free
> connection from that pool. Under a sudden burst to 2000 concurrent
> requests, only as many requests as there are pool slots can actually be
> running a query against MySQL at once; the rest queue *inside the
> application tier*, waiting for a connection to free up. From MySQL's point
> of view it only ever sees a handful of concurrent trivial queries (hence
> low CPU/disk — "the DB is bored"), while from the caller's point of view
> most of the latency is time spent waiting in the pool's queue before the
> query even starts. This also explains instant recovery once load drops:
> once arrivals fall below the pool's service rate, the queue drains and
> nothing needs repair.

### Observation (evidence)
> Where is time spent between request arrival and query execution? Capture the
> error codes and any queue/timeout evidence from logs and metrics:
> ```
> docker stats during reproduce-OPS-2202.js (2000-VU burst, connectionLimit=2):
>   mysql-db:      CPU 0.83%   MEM 12.08% (473MiB/3.8GiB)   -- essentially idle
>   capacity-api:  CPU 0.66%   MEM 36.70% (58.71MiB/160MiB) -- also idle
>
> k6 (200 VUs -> this ticket uses 2000 VUs, ramping-vus 0->2000 over 5s, held 30s):
>   p95=3.38s  avg=1.08s  med=930ms  max=5.21s
>   http_req_failed: 0.00% (0/52990) -- ticket also mentions 500s; not reproduced
>                                        at connectionLimit=2, only latency
>
> api/database.js MYSQL_CONFIG: connectionLimit: 2, queueLimit: 0 (unlimited
> queue depth -- explains 0% errors + high latency rather than fast rejections)
>
> EXPLAIN ANALYZE SELECT * FROM patients ORDER BY id DESC LIMIT 50;
> -> Limit: 50 row(s) (actual time=0.859..1.73 rows=50 loops=1)
>     -> Index scan on patients using PRIMARY (reverse) (actual time=0.856..1.5)
> -- query itself is cheap and well-indexed; not the bottleneck.
> ```
| Metric                    | Value | vs. baseline |
|---------------------------|-------|--------------|
| Successful RPS (plateau)  | 1620 req/s | vs. baseline 48.84 req/s (higher raw throughput, but severely degraded latency) |
| p95 / p99 latency         | p95=3.38s (p99 not captured this run) | ~43x worse than baseline p95=78.26ms |
| Error / timeout rate      | 0.00% (0/52990) | same as baseline -- but median request took 930ms, not truly healthy |
| Avg service time per query (s) | ~0.00173s (1.73ms, measured via EXPLAIN ANALYZE, uncontended) | negligible -- confirms query cost is not the bottleneck |

### Root cause & mechanism
> Explain the paradox: idle database, trivial query, stalled app. What finite
> resource is being contended, and where does it live? Derive the *right* size
> for that resource from your measured throughput and service time (state the
> relationship you used):
>
> **Mechanism: undersized application-side MySQL connection pool
> (`connectionLimit: 2` in `api/database.js`).** A query cannot execute until
> the request first acquires one of the pool's connections. With only 2
> connections, at most 2 requests can be running a query against MySQL at any
> instant, no matter how many requests have arrived. Every other request sits
> in an in-process queue inside the pool library (`queueLimit: 0` = unbounded
> queue, which is why we saw 0% errors rather than fast rejections -- everyone
> waits instead of failing). This resolves the paradox precisely: MySQL only
> ever sees ~2 concurrent trivial queries, so its CPU/disk stay flat ("the DB
> is bored") -- but the *caller* experiences most of its latency as queueing
> time inside the app tier, before the query even starts. This is confirmed
> by `docker stats` showing both mysql-db (0.83% CPU) and capacity-api (0.66%
> CPU) essentially idle even while k6 measured p95=3.38s -- neither machine
> was doing meaningful work; requests were simply waiting in line.
>
> - Measured avg service time W = 0.00173 s (1.73ms, `EXPLAIN ANALYZE`,
>   uncontended, primary-key index scan -- this query was never the problem)
> - Target throughput λ = 1620 req/s (measured arrival/completion rate during
>   the reproduction)
> - Required capacity (Little's Law, L = λ x W) = 1620 x 0.00173 ≈ **2.8
>   concurrent connections** needed on average just to keep up with steady
>   arrivals -- already above the configured limit of 2.
> - Theoretical max throughput of a pool of 2 = connections / W = 2 / 0.00173s
>   ≈ **1156 req/s** -- a hard ceiling below the 1620 req/s of arrivals we
>   measured, so queueing was mathematically guaranteed regardless of burst
>   shape, not just a symptom of the sudden ramp.
>
> Why does making it arbitrarily large eventually stop helping? Raising
> `connectionLimit` to 20 alone (with `LIMIT 50` still on `/recent`) improved
> p95 (3.38s -> 2.63s) and confirmed via `SHOW STATUS LIKE
> 'Max_used_connections'` (=21, essentially the full pool) that MySQL
> accepted and used all of them without hitting its own `max_connections`
> ceiling (151). But that alone did **not** fully resolve the incident, and
> introduced a *new* failure mode: `docker stats` during that retest showed
> capacity-api CPU spike to **173%** and memory climb to 120/160MiB (75%)
> mid-run, and k6 reported a new 0.37% error rate (`connection reset by
> peer`) plus a much worse tail (max=22.78s vs 5.21s before), with failures
> clustering ~12-14s into the sustained 2000-VU load rather than at the
> initial ramp. `RestartCount: 0` and clean logs ruled out an OOM-kill/
> crash-restart loop -- the process stayed alive throughout. This pointed to
> a **second, independent bottleneck**: with the connection pool no longer
> the limiting factor, concurrency downstream became the new ceiling —
> confirmed by testing directly (see Fix): each `/recent` response was
> 18,145 bytes (50 rows, including a full unbounded `notes TEXT` field per
> row); at 2000 concurrent requests that's ~36MB of JSON being built and
> serialized on Node's single JS thread simultaneously, competing with
> routing, the MySQL driver, and V8 garbage collection for the same thread —
> `JSON.stringify` is synchronous and blocks the event loop, so this is real,
> serial CPU work, not queueing. This is the same lesson as OPS-2201 in a
> different shape: fixing one finite resource (connections) just exposed the
> next one (event-loop/serialization time), and "arbitrarily large" doesn't
> help once you've shifted the bottleneck to a resource that scaling a
> connection-pool number can't touch.

### Fix & verify
> The change you made: two changes, both required — evidence showed the
> first alone was insufficient, same pattern as OPS-2201:
> 1. Raised `connectionLimit` (and `maxIdle`) from 2 to 20 in
>    `api/database.js`, sized from the Little's Law calculation above (~2.8
>    needed on average, ~7x headroom for burstiness, well under MySQL's own
>    `max_connections=151`).
> 2. Reduced `/api/patients/recent`'s query from `LIMIT 50` to `LIMIT 10` in
>    `api/server.js`, shrinking per-response payload (and therefore
>    serialization work) roughly 5x.
>
> **Step 1 alone (`connectionLimit=20`, `LIMIT 50`):** p95 3.38s -> 2.63s
> (~22% better), but a *new* 0.37% error rate appeared (`connection reset by
> peer`) and `docker stats` showed capacity-api CPU spike to 173%, memory to
> 120/160MiB (75%) — a regression in kind, not just degree.
>
> **Step 1 + 2 together (`connectionLimit=20`, `LIMIT 10`), confirmed with
> two separate reproduction runs:**
> ```
> Run 1: p95=1.52s  RPS=2779.6/s  errors=0.00%  data=330MB
> Run 2: p95=1.25s  RPS=2722.3/s  errors=0.00%  data=323MB
> Live docker stats mid-run (Run 2): capacity-api CPU=0.83%, MEM=78.38MiB/160MiB (49%)
> ```
> New p95: **~1.25-1.52s** (vs. broken 3.38s; vs. pool-only-fix 2.63s; vs.
> baseline 78.26ms — still well above baseline, but a genuinely stable,
> passing result)
> New RPS: **~2722-2780 req/s** (vs. broken 1620 req/s, ~68-72% more
> throughput)
> New error rate: **0.00%** (was 0.37% after step 1 alone; threshold
> `rate<0.05` now passes cleanly, not marginally)
> CPU under load: **0.83%** (vs. 173% after step 1 alone) — confirms the
> event-loop/serialization theory directly: shrinking payload size
> eliminated the CPU spike, not just the symptom.
>
> Any trade-off introduced by your fix? The "recent patients" widget now
> shows 10 patients instead of 50 — a real, visible reduction in
> functionality for on-call staff glancing at recent admissions, not a free
> win. This mirrors OPS-2201's `LIMIT` trade-off: a production version would
> want the full 50 (or more) back via pagination or a lighter-weight column
> selection (e.g. omitting `notes` from the list view, fetching it only on
> detail-view) rather than permanently showing fewer patients. The
> connection-pool increase carries the same MySQL-side overhead discussed in
> OPS-2201's write-cost note, negligible at this scale.
>
> What upstream protection would make a burst degrade gracefully instead of
> collapsing? A **request queue with a hard cap and fast-fail** (e.g. reject
> with 503 once N requests are already queued, instead of `queueLimit: 0`
> letting the queue grow unbounded) would convert "everyone waits
> indefinitely" into "some requests fail fast while others succeed quickly" --
> better for callers overall, and it would have surfaced this ticket's "or
> returns 500s" symptom explicitly instead of only as extreme latency. A
> rate limiter or admission-control middleware in front of the API would
> shed excess load before it reaches either the pool or the event loop.

---

## Investigation — OPS-2203
*Ticket:* [Bed admissions fail with DB errors under load](./incidents/OPS-2203.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2203.js`

### Hypothesis
> Given one-at-a-time works but concurrent admits to the *same* hospital fail,
> I think the cause is _____________________________________________________
> and the failure will show up as ______ (a DB error? a timeout? a stall?) ___.

### Observation (evidence)
> While the reproduction runs, inspect concurrent writers to one row:
> ```sql
> SELECT * FROM performance_schema.data_locks\G
> SELECT * FROM sys.innodb_lock_waits\G
> SHOW ENGINE INNODB STATUS\G   -- TRANSACTIONS section
> ```
> Paste the most telling waiter/blocker rows and the failure signature you saw
> (a DB error + code, a timeout, or stalled/near-zero throughput):
> ```
>
> ```
| Metric                     | Value | vs. baseline |
|----------------------------|-------|--------------|
| p95 / p99 latency          |       |              |
| Max successful admits/sec  |       |              |
| DB error(s) + code         |       |              |
| Error rate                 |       |              |

### Root cause & mechanism
> Explain why concurrency cannot beat serialization on a single hot row. If the
> critical section is held for W seconds per admit, what is the theoretical max
> throughput for that one row, regardless of how many callers pile on?
> 1 / W = ______ admits/sec. Where does the time in the critical section go, and
> which of the transactional guarantees is enforcing the wait? ________________

### Fix & verify
> The change you made (consider: shrinking the critical section, moving slow
> work out of the transaction, atomic guarded updates, reducing contention on
> the hot row): _____________________________________________________________
> Re-measured throughput / error rate: ______________________________________

---

## Investigation — OPS-2204
*Ticket:* [Nightly export crashes the service repeatedly](./incidents/OPS-2204.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2204.js`

### Hypothesis
> Given memory spikes right before each restart and only the big export is
> affected, I think the cause is ___________________________________________
> because __________________________________________________________________.

### Observation (evidence)
> Watch `nodejs_heap_size_used_bytes`, GC pauses, and restarts:
> ```bash
> docker stats
> docker compose logs -f capacity-api
> ```
| Metric                          | Value |
|---------------------------------|-------|
| Approx. payload size per request|       |
| Peak heap before crash          |       |
| Time-to-first-crash             |       |
| Container restart count         |       |
| GC pause trend                  |       |

> Paste the crash / exit log lines:
> ```
>
> ```

### Root cause & mechanism
> Estimate per-row size, then the full payload: rows × bytes/row = ______ MB.
> With C concurrent callers, peak resident memory ≈ ______ MB — compare to the
> container's memory budget (160MB locally / 256MB in prod). Explain what happens
> to GC frequency, CPU, and
> throughput as live heap approaches the limit, and why the current approach
> uses O(N) memory while a better one could use far less. ____________________

### Fix & verify
> The change you made (consider: bounding how much of the result set is in
> memory at once, streaming to the response, sensible page sizes, compression):
> ____________________________________________________________________________
> Re-run evidence — new peak heap: ______  restarts: ______  error rate: ______

---

## Post-incident review (synthesis)

> Rank the four incidents by **blast radius** (threat to overall availability at
> scale), justified with your measured numbers:
> 1. ____________________________________________________________________
> 2. ____________________________________________________________________
> 3. ____________________________________________________________________
> 4. ____________________________________________________________________
>
> If you could ship only **one** fix before a launch, which and why?
> ____________________________________________________________________________
>
> For each incident, what alert or dashboard would have caught it in production
> *before* a user filed a ticket? ____________________________________________
