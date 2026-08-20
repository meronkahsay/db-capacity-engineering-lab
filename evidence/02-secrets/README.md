# C2/C3 — Secrets Manager wiring evidence

**Status:** ⏳ needs a live apply (see [../01-iac](../01-iac)) to capture real
`aws secretsmanager get-secret-value` output against the deployed instance.

## What goes here

- `secret-describe.txt` — `awslocal secretsmanager describe-secret` for the
  DB credential secret, proving it exists and is the only place creds live
  (never in Terraform state as plaintext var, never in an env var baked into
  the AMI).
- `no-hardcoded-creds.txt` — grep across the deployed image / user-data
  output showing no plaintext DB password anywhere (`docker history`,
  `strings` on the built image, or the rendered user-data script).
- Reference: `api/database.js` resolves `DB_SECRET_ARN` → `GetSecretValueCommand`
  at boot; no `MYSQL_CONFIG`-style hardcoded default exists in this codebase
  (removed — see git history).
