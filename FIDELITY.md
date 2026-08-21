# FIDELITY.md — where LocalStack diverges from real AWS

This documents every place the deployed-on-LocalStack behavior differs from
what the same Terraform would do against real AWS, found by hitting the
divergence directly (not by reading LocalStack's docs list) while building
this rehost.

## 1. ELBv2 not included in the freemium license

`aws_lb` / `aws_lb_target_group` / `aws_lb_listener` creation fails on
LocalStack's free tier with:

```
Sorry, the elbv2 service is not included within your LocalStack license,
but is available in an upgraded license.
```

The Terraform for the ALB is real and still declared (in
`regional-health-platform`'s `terraform/modules/service`), scanned by
trivy/zizmor like any other resource, and will create a real ALB against
actual AWS. On LocalStack it's gated behind a `create_alb` variable
(default `false`) so the rest of the stack (EC2, Secrets Manager, security
group) can actually apply. This matches the assignment's own framing: nginx
on the instance carries the real traffic and does the real readiness
gating in this lab; the ALB is graded as IaC, not as a live routing path.

**Real-AWS behavior:** `create_alb = true` creates a real internet-facing
ALB with a target group pointed at the instance's nginx on port 80, health
-checked against `/readyz`.

## 2. S3 backend credential injection doesn't cover Terraform's own state init

`tflocal` (the LocalStack Terraform wrapper) auto-injects
`endpoints {}`/dummy credentials into the **AWS provider block**, but
Terraform resolves its **S3 backend** (for remote state) before the
provider override applies. A plain `tflocal init` against an S3 backend
fails with:

```
No valid credential sources found ... EC2 IMDS ...
```

**Fix applied:** pass explicit `-backend-config` flags at init time:
`access_key=test`, `secret_key=test`, `skip_credentials_validation=true`,
`skip_metadata_api_check=true`, `skip_requesting_account_id=true`, and
`endpoints={s3="...",dynamodb="..."}` pointed at the LocalStack endpoint.

**Real-AWS behavior:** the backend resolves credentials normally (instance
profile, `~/.aws/credentials`, or CI OIDC) — no special init flags needed.

## 3. LocalStack workspace / license is per-account, not per-repo

`localstack start` reported `licensing.license.not_assigned` the first
time, even with a valid `LOCALSTACK_AUTH_TOKEN` set. Root cause: the token
belonged to a **shared org workspace** with no license seat assigned, not a
personal LocalStack account. Creating/activating a personal LocalStack
account and using that token's `LOCALSTACK_AUTH_TOKEN` fixed it — freemium
license auto-activated with no ELBv2 coverage (see #1).

This has no real-AWS analogue — it's purely a LocalStack account-model
quirk, worth documenting so the next person doesn't waste time thinking
it's a Terraform or Docker problem.

## 4. IMDSv2 enforcement can't be exercised at runtime

`aws_instance.app` sets `metadata_options { http_tokens = "required" }`
(IMDSv2-only, satisfies AWS-0028 in trivy config). LocalStack's IMDS
emulation is limited — no `iam/security-credentials/` path — so this
setting can't be verified by actually curling the instance metadata
endpoint the way it could against real AWS. The Terraform is correct and
would enforce IMDSv2 for real; it's simply unverifiable end-to-end in this
environment.

## 5. Storage/root-volume encryption is echoed back, not real

`root_block_device { encrypted = true }` is accepted and returned as
`encrypted = true` in LocalStack's state, but LocalStack does not perform
real encryption-at-rest the way AWS EBS does. Same category as RDS's
`storage_encrypted` flag in `modules/data` — the Terraform is the correct,
real-AWS-transferable configuration; LocalStack's enforcement of it is
cosmetic.

## 6. Docker-backed EC2 AMI tagging format

CI tags the app's Docker-backed "AMI" as
`localstack-ec2/<name>:ami-<12 hex chars>` (LocalStack's Docker-backed EC2
emulation, not a real AMI). `aws_instance.ami` / `DescribeImages` on real
AWS only accepts a bare `ami-<hex>` id, so `modules/service/main.tf` strips
everything through the last colon before passing it to the resource — a
value that's already a bare `ami-<hex>` id passes through unchanged, so the
same Terraform works against a real AMI id with no branch.

## 7. Docker-backed EC2 needs the full localstack-ec2/ tag, not the AWS-style bare id

Hit live during a real `tflocal apply` (2026-08-21, see
`evidence/01-iac/README.md` for the full writeup). `aws_instance.app`
failed with `couldn't find resource`, and LocalStack's own logs showed
`ec2.DescribeImages => 400 (InvalidAMIID.NotFound)`.

`modules/service/main.tf` strips the CI-computed AMI tag
(`localstack-ec2/<name>:ami-<sha12>`) down to a bare `ami-<sha12>` before
passing it to `aws_instance.ami`, reasoning that real AWS's
`DescribeImages` only accepts the bare form. That's correct for real AWS —
but LocalStack's Docker-backed EC2 emulation resolves the AMI by looking
for a **Docker image whose repo:tag exactly matches the full string**
(`localstack-ec2/<name>:ami-<sha12>`), so the stripped bare id can never
resolve to anything on LocalStack, regardless of what's tagged locally.

Confirmed directly, not guessed: `docker images` showed the image present
under the correct `localstack-ec2/capacity-api:ami-<sha12>` tag;
`docker inspect localstack-main` confirmed `/var/run/docker.sock` was
correctly mounted (ruling out a Docker-in-Docker isolation issue);
`docker logs localstack-main` showed the exact `DescribeImages` 400 at the
moment of instance creation.

The group's own `golden-ci.yml` `tflocal-apply` job appears to have the
same gap for a different reason: it builds and uploads the image as a
GitHub Actions artifact in the separate `docker-build` job, but the
`tflocal-apply` job — which starts its own fresh LocalStack — has no step
that loads that image tarball back into Docker before calling `tflocal
apply`. `run_apply: true` only fires on push-to-main, so this path may
never have been exercised end-to-end.

**Real-AWS behavior:** a real AMI id (`ami-0abcd1234...`) resolves via the
real EC2 API regardless of any Docker image state — this entire class of
failure doesn't exist off LocalStack.

**Update (2026-08-21):** the trainer independently confirmed the actual
root cause is one level up from the tag-format issue above: real
Docker-backed EC2 (a backing container you can boot and curl) is a
LocalStack **Base+ paid feature**. The free Hobby tier used for this lab
gives a mock EC2 only — `RunInstances` returns a "running" instance with no
backing container, so `DescribeImages`/`describe-images --owners self`
never resolves an image regardless of tag format. The AMI-tag fix above is
still correct and worth keeping (it fixes a real format mismatch for
whoever eventually runs this against a paid LocalStack tier or real AWS),
but it was not, in the end, what was blocking this specific apply. Per the
updated brief: EC2 and ALB are both graded as IaC only (write it, apply the
mock/skip the apply, never expect either to actually route traffic on this
tier); the real runtime is `scripts/run-app.sh`, running the app container
directly against the same Secrets Manager secret and Aiven database.

## 8. LocalStack Hobby tier's EC2 is mock-only — confirmed by the trainer, not just inferred

Documented separately from #7 above because it's a distinct, more
fundamental fact about the platform, not a code bug: on the free Hobby
tier, `aws_instance` (EC2) creation succeeds and returns a real-looking
instance ID, but there is **no backing Docker container** — no
`ec2_vm_manager:docker` tag, nothing to `docker exec` into or curl
user-data output from. `awslocal ec2 describe-images --owners self`
returns empty even immediately after a real, correctly-tagged `docker
build` — because the mock EC2 provider never looks at Docker images at
all, correct tag or not. This matches every symptom hit while debugging
#7, and was confirmed directly by Rob (trainer) in response to the same
failure reported by another group, not inferred from LocalStack's own
docs (which don't clearly state this tier boundary for EC2 the way they do
for ELBv2's licensing error message).

**Real-AWS behavior:** `RunInstances` creates a real EC2 instance that
actually boots the given AMI and runs user-data — no Docker involvement at
all, so this entire class of limitation is specific to LocalStack's
emulation layer and doesn't exist off it.

---

None of the above required weakening the Terraform to work around
LocalStack — every fix either (a) only affects the local dev/CI loop
(backend-config flags, workspace setup) or (b) is a variable defaulting to
the LocalStack-safe value while remaining fully real for actual AWS
(`create_alb`).
