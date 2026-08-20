# C3 — /healthz evidence

**Status:** ⏳ needs a live apply to hit the real instance; the endpoint
itself is implemented and locally verified (`api/server.js`).

## What goes here

- `healthz-200.txt` — `curl -i http://<instance-or-nginx>/healthz` showing
  `200 {"status":"ok"}` while the process is alive, regardless of DB state
  (liveness only — never checks the DB, by design; see server.js comment at
  api/server.js:74-81).
