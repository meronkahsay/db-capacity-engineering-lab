# lb-design — ALB as IaC, never applied

Per Rob's 2026-08-21 clarification on the assignment (relayed in the group
channel): ELBv2 (ALB) is a LocalStack Base+ feature, not available on the
free Hobby tier used for this lab — same tier gate that made Docker-backed
EC2 return a mock instance instead of a real one (see `../FIDELITY.md`).

This directory is graded as infrastructure-as-code: it's real, validated,
scanned Terraform for the production-real front door this service would
use (a real ALB with a target-group health check against `/readyz`) — but
it is **deliberately never `tofu apply`'d** here. On LocalStack's Hobby
tier, applying it would fail with the same
`"the elbv2 service is not included within your LocalStack license"` error
documented in `../FIDELITY.md` #1.

## What's here

- `main.tf` / `variables.tf` / `outputs.tf` — a standalone ALB + target
  group + listener + security group, matching the exact resource shapes
  and trivy-suppression rationale already used in
  `regional-health-platform`'s `modules/service` (kept in sync
  deliberately, not duplicated by accident).

## What's validated (not applied)

```bash
cd terraform/lb-design
tofu init -backend=false
tofu validate
tofu plan   # will fail past the planning stage against LocalStack's Hobby
            # tier once it tries to resolve the elbv2 API -- expected, same
            # root cause as FIDELITY.md #1. `tofu validate` and `trivy
            # config`/`zizmor` are what actually run here; `tofu plan`
            # against real AWS (or a Base+ LocalStack license) would
            # succeed unchanged.
```

## Why this design, not modules/service's inline ALB

`modules/service`'s `aws_lb`/`aws_lb_target_group`/`aws_lb_listener`
resources (gated behind `create_alb`, see that module's `main.tf`) remain
in place for the group's own composition and are unaffected by this. This
`lb-design/` directory is a standalone, individually-graded restatement of
the same design as its own root module, per the updated brief's
instruction to keep the ALB as unapplied IaC in
`terraform/lb-design/` specifically.
