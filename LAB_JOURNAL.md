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
> the bottleneck is ________________________________________________________
> because __________________________________________________________________.

### Observation (evidence)
> Where is time spent between request arrival and query execution? Capture the
> error codes and any queue/timeout evidence from logs and metrics:
> ```
>
> ```
| Metric                    | Value | vs. baseline |
|---------------------------|-------|--------------|
| Successful RPS (plateau)  |       |              |
| p95 / p99 latency         |       |              |
| Error / timeout rate      |       |              |
| Avg service time per query (s) |  |              |

### Root cause & mechanism
> Explain the paradox: idle database, trivial query, stalled app. What finite
> resource is being contended, and where does it live? Derive the *right* size
> for that resource from your measured throughput and service time (state the
> relationship you used):
> - Measured avg service time W = ______ s
> - Target throughput λ = ______ req/s
> - Required capacity = ______  (show your working)
> Why does making it arbitrarily large eventually stop helping? ______________

### Fix & verify
> The change you made: ______________________________________________________
> New RPS: ______  New error rate: ______  New p95: ______
> What upstream protection would make a burst degrade gracefully instead of
> collapsing? _______________________________________________________________

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
