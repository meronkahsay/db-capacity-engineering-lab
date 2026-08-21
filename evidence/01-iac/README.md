# C1 — IaC apply evidence

**Status:** ⚠️ partial apply, real infra created and destroyed cleanly, one
resource blocked by a LocalStack limitation — see below and FIDELITY.md.

## What actually happened (2026-08-21, LocalStack freemium, Codespace)

A real `tflocal apply` was run end-to-end against a fresh S3+DynamoDB state
backend (see `bootstrap/` in the group repo). Three of four planned
resources created successfully:

- `module.data.aws_secretsmanager_secret.db` ✅
- `module.data.aws_secretsmanager_secret_version.db` ✅
- `module.service.aws_security_group.app` ✅ (correctly scoped ingress —
  port 80 only, from the VPC CIDR; egress limited to DNS/HTTP/HTTPS/Aiven's
  db_port)
- `module.service.aws_instance.app` ❌ — see below
- `aws_lb`/`aws_lb_target_group`/`aws_lb_listener` — correctly **skipped**
  (`create_alb = false` default working as designed; `alb_dns_name` output
  came back `""` exactly as coded — see FIDELITY.md #1)

Full logs: [`apply.log`](apply.log), [`destroy.log`](destroy.log).

## Root cause of the aws_instance.app failure

LocalStack's Docker-backed EC2 emulation resolves the `ami` field by
looking for a **Docker image whose repo:tag literally matches the AMI
string** it's given. `modules/service/main.tf`'s `local.app_ami_id` strips
the value CI computes (`localstack-ec2/<name>:ami-<sha12>`) down to the
bare `ami-<sha12>` form, on the stated assumption that real AWS's
`DescribeImages` only accepts a bare id. That stripping is correct for real
AWS, but on LocalStack it means the resource looks up `ami-e7dfd6c45c69` —
a tag that was never applied to any Docker image (the actual image was
tagged `localstack-ec2/capacity-api:ami-e7dfd6c45c69`) — and LocalStack's
own log confirms this directly:

```
AWS ec2.DescribeImages => 400 (InvalidAMIID.NotFound)
```

Confirmed by direct inspection, not guesswork: `docker images` showed the
image present under both tags; `docker inspect localstack-main` confirmed
`/var/run/docker.sock` was correctly mounted into the LocalStack container
(ruling out a Docker-in-Docker isolation issue); `docker logs localstack-main`
showed the exact `DescribeImages` 400 at the moment of instance creation.

This same gap appears to exist in the group's own `golden-ci.yml`
`tflocal-apply` job: it builds and saves the image as a GitHub Actions
artifact in the `docker-build` job, but the `tflocal-apply` job (which
starts a fresh LocalStack) has no step that loads that image tarball back
into Docker before calling `tflocal apply` — meaning `run_apply: true`
(push-to-main only) has likely never actually exercised a full instance
creation either.

## What this evidence proves

- The Terraform for Secrets Manager, the security group, and the
  conditional ALB gating is correct and creates real resources on
  LocalStack.
- `create_alb = false` behaves exactly as designed.
- The stack tears down cleanly with no orphaned resources
  (`destroy.log`: "Destroy complete! Resources: 3 destroyed").
- The one remaining gap is a LocalStack Docker-backed-EC2 image-resolution
  quirk in `modules/service`'s AMI-id-stripping logic (group-owned code),
  not a defect in this repo's root module or variable wiring.

## Fix for next time (not applied under the submission deadline)

Either: (a) don't strip the tag when it's a `localstack-ec2/...` value —
pass it through unchanged and only strip for a bare real-AWS AMI id, or
(b) add a `docker load` step in `golden-ci.yml`'s `tflocal-apply` job
before calling `tflocal apply`, using the `docker-build` job's saved
artifact, matching what a human running this by hand must do (`docker tag
<image> localstack-ec2/<name>:ami-<sha12>` before `apply`).
