# C1 — IaC apply evidence

**Status:** ⏳ blocked on `regional-health-platform` PR #11 (ALB-conditional fix)
merging, then re-pinning `terraform/main.tf`'s `platform_ref` and
`.github/workflows/ci.yml`'s pinned SHA in this repo.

## What goes here once unblocked

- `apply.log` — full `tflocal apply` output (EC2 + Secrets Manager + security
  group; `aws_lb`/`aws_lb_target_group`/`aws_lb_listener` skipped via
  `create_alb = false`, declared but not created — see FIDELITY.md).
- `plan-after-apply.txt` — `tflocal plan` immediately after apply, showing no
  diff (proves the config is idempotent).
- `destroy.log` — `tflocal destroy`, proving the stack tears down cleanly.

## How to reproduce

```bash
cd terraform
export LOCALSTACK_AUTH_TOKEN=...
localstack start -d
tflocal init -backend-config=... # see terraform/README or main.tf comments
tflocal apply -auto-approve | tee ../evidence/01-iac/apply.log
tflocal plan | tee ../evidence/01-iac/plan-after-apply.txt
tflocal destroy -auto-approve | tee ../evidence/01-iac/destroy.log
```
