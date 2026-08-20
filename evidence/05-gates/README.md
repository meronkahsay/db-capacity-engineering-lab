# C5 — CI gates genuinely block (red-PR evidence)

**Status:** ⏳ not started — no infra dependency, can be done any time.

Per gate, prove the gate is not theatre: introduce one deliberate insecure
change, show CI failing red on it, then the fix commit that turns it green
again. One example per gate is enough; link PR + failing run + fix commit.

## Planned red-PR per gate

| Gate | Deliberate insecure change | Expected failure |
|---|---|---|
| gitleaks | Commit a fake AWS-shaped secret string in a scratch file | gitleaks job fails, blocks merge |
| trivy config | Flip `local.ingress_cidrs` fallback (or an override) to `0.0.0.0/0` on port 80 | `trivy config` flags open ingress (AVD-AWS-xxxx), blocks merge |
| zizmor | Remove the explicit `permissions: contents: read` block from `ci.yml` | zizmor's excessive-permissions finding fires, blocks merge |

## What goes here once done

- `gitleaks-red/` — PR link, failing Actions run screenshot/log, fix commit link.
- `trivy-config-red/` — same structure.
- `zizmor-red/` — same structure.
- `README.md` (this file) updated with the three PR links.

Do this against **this repo** (`db-capacity-engineering-lab`), not the group
repo — it's individually graded evidence, and doesn't touch shared main.
