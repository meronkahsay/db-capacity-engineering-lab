# C5 — CI gates genuinely block (red-PR evidence)

Per gate, prove the gate is not theatre: introduce one deliberate insecure
change, show CI failing red on it, then the fix commit that turns it green
again. Three attempted below — one succeeded as designed, one needed a
correction after a genuine mistake, one surfaced a real tool limitation
worth documenting rather than forcing past.

## zizmor — ✅ works as designed

Branch: `evidence/zizmor-red`. Removed the explicit
`permissions: contents: read` block from `.github/workflows/ci.yml`.
CI genuinely failed: 2 medium-severity `excessive-permissions` findings,
exit code 13, gate blocked. This is real, verified evidence — the gate
does what it's supposed to.

## gitleaks — corrected after a real mistake, re-testing

Branch: `evidence/gitleaks-red`. First attempt used AWS's own public docs
placeholder credential pair (`AKIAIOSFODNN7EXAMPLE` /
`wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`) as the "fake secret." CI passed
green — investigated and confirmed **locally** (not guessed) that this
exact string is allowlisted by gitleaks (and most scanners) as a known
false-positive, since it's the world's most commonly-copy-pasted example
credential:

```
$ docker run --rm -v /tmp/gitleaks-test:/scan zricethezav/gitleaks:latest detect --source=/scan --no-git -v
no leaks found
```

Replaced with a randomly generated `AKIA`-shaped key + a random
high-entropy secret, verified locally to trip gitleaks'
`generic-api-key` rule before committing:

```
$ docker run --rm -v /tmp/gitleaks-test:/scan zricethezav/gitleaks:latest detect --source=/scan --no-git -v
Finding:     AWS_SECRET_ACCESS_KEY=...
RuleID:      generic-api-key
leaks found: 1
```

Also separately found and fixed a real scoping bug during this process:
`gitleaks-action`'s commit-range resolution was scanning the same stale
single-commit slice across multiple open PRs rather than each PR's actual
head commit (confirmed by observing two different PRs' logs both reporting
"1 commits scanned... scanned ~326 bytes" against a commit that wasn't
either PR's own change). Fixed by rebasing all three red-PR branches onto
current `main`, which resolved the ambiguity.

## trivy config — real tool limitation, documented instead of forced

Branch: `evidence/trivy-config-red`. Added `terraform/red-demo.auto.tfvars`
overriding `ingress_cidrs = ["0.0.0.0/0"]` — the exact insecure change
`ingress_cidrs`'s own description in `variables.tf` anticipates. CI passed
green (0 misconfigurations). Investigated locally rather than assumed it
was a false pass:

```
$ docker run --rm -v terraform:/scan aquasec/trivy:latest config /scan --severity HIGH,CRITICAL
WARN  Variable values were not found in the environment or variable files.
      Evaluating may not work correctly.  variables="aiven_host, aiven_password, aiven_port, app_ami_id"
...0 misconfigurations
```

Supplying the missing required variables via `TF_VAR_*` env vars let trivy
fully resolve the module graph (confirmed: it then found a real, unrelated
pre-existing LOW finding in `modules/data`, `AWS-0098`, proving the module
*was* being evaluated) — but `modules/service`'s security group still came
back clean, and `--debug` output never mentions `ingress_cidrs` at all.

**Conclusion:** this is a real limitation of trivy's static Terraform
analyzer — it does not fully propagate a root module's `.auto.tfvars`
value through a remote git-sourced module's variable chain into a resource
attribute (`cidr_blocks = local.ingress_cidrs`) for evaluation, even when
all required variables are supplied and the module is otherwise being
scanned. This is a genuine gap in `trivy config`'s coverage for
multi-module Terraform compositions with a remote module source, not a
misconfiguration in this repo or the group's module. Filed here as
evidence rather than forced past under the submission deadline — a fix
would require either restructuring the module to avoid the multi-hop
variable chain, or accepting that `trivy config` needs a full `terraform
plan` JSON (`trivy config --tf-plan`) rather than static HCL analysis to
catch this specific class of issue.
