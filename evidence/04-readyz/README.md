# C4 — /readyz flip evidence (highest-signal Core evidence per the brief)

**Status:** ⏳ needs a live apply. This is the most important piece of
evidence in the individual submission — prove the readiness gate actually
gates, not just that the route exists.

## What goes here

1. `readyz-200-healthy.txt` — `curl -i .../readyz` → `200 {"ready":true}`
   against the healthy deployed stack.
2. `readyz-503-broken.txt` — after deliberately breaking DB reachability
   (e.g. temporarily revoke the security group egress to Aiven's port, or
   rotate the secret to a bad password), `curl -i .../readyz` → `503
   {"ready":false,"reason":"..."}`. Capture the exact reason string from
   `checkDbReady()` (api/database.js) — distinguishes "secret unresolvable"
   from "DB unreachable" from "pool saturated".
3. `readyz-recovered-200.txt` — after reverting the break, `/readyz` back to
   200, proving the gate self-heals once the real dependency recovers.
4. If nginx is in front (per modules/service): show that nginx's own
   upstream check (or the ALB target-group health check, if `create_alb=true`
   on real AWS) also flips on the same signal.

## How to reproduce

```bash
# break it (example: bad secret rotation)
awslocal secretsmanager put-secret-value --secret-id <arn> --secret-string '{"password":"wrong"}'
curl -i http://<host>/readyz | tee ../evidence/04-readyz/readyz-503-broken.txt

# fix it
awslocal secretsmanager put-secret-value --secret-id <arn> --secret-string '<original envelope>'
curl -i http://<host>/readyz | tee ../evidence/04-readyz/readyz-recovered-200.txt
```
