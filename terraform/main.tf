# =============================================================================
# Root module — capacity-api individual rehost
#
# Composes the group platform's modules/data + modules/service. Sourced by
# pinned commit SHA (never a moving branch), matching
# regional-health-platform/README.md's own documented consumption pattern.
# Bump the ref deliberately when picking up a group module change, not
# silently.
# =============================================================================

locals {
  # Pinned to regional-health-platform's integration/individual-unblock
  # branch (commit 3cab12d) as of 2026-08-21: main + fix/trivy-image-
  # ignore-unfixed + fix/service-alb-optional-localstack + feat/state-
  # bootstrap + fix/service-ami-tag-localstack merged together, ahead of
  # those PRs landing on main via GitHub's merge button. Re-pin to a
  # post-merge main SHA once they land -- functionally identical, this just
  # unblocks apply now. Adds: create_alb variable (default false, LocalStack
  # elbv2 isn't licensed), ignore-unfixed on the trivy image scan,
  # bootstrap/ (S3+DynamoDB state store, not consumed by this module
  # directly), and the AMI-tag fix (module no longer strips the
  # localstack-ec2/<name>:ami-<hex> tag when targeting LocalStack -- see
  # FIDELITY.md #7 and evidence/01-iac/README.md for why the first apply
  # attempt failed without this).
  platform_ref = "3cab12d1d9e749e30b0627c52ecfe00efb14e1de"
}

module "data" {
  source = "git::https://github.com/nebyathhailu/regional-health-platform.git//terraform/modules/data?ref=${local.platform_ref}"

  name_prefix    = var.name_prefix
  db_name        = var.db_name
  secret_name    = var.secret_name
  aiven_host     = var.aiven_host
  aiven_port     = var.aiven_port
  aiven_username = var.aiven_username
  aiven_password = var.aiven_password
  tags           = var.tags
}

module "service" {
  source = "git::https://github.com/nebyathhailu/regional-health-platform.git//terraform/modules/service?ref=${local.platform_ref}"

  name_prefix       = var.name_prefix
  app_ami_id        = var.app_ami_id
  app_port          = var.app_port
  app_start_command = "node server.js"
  # Matches api/Dockerfile's WORKDIR exactly (not the modules/service default
  # of /app) — checked the Dockerfile directly rather than assume.
  app_workdir = "/usr/src/app"

  # Never the secret value — only the ARN. The app resolves the value itself
  # via GetSecretValue at boot (C3).
  secret_arn  = module.data.secret_arn
  db_endpoint = module.data.db_endpoint
  db_port     = module.data.db_port

  # Aiven's CA cert — public root cert, not secret (same reasoning
  # modules/data uses to keep it out of the Secrets Manager envelope).
  # modules/service writes this to /etc/app/db-ca.pem on the instance and
  # exports DB_CA_CERT_PATH, matching database.js's fallback default exactly.
  db_ca_cert = file("${path.module}/aiven-ca.pem")

  aws_endpoint_url = var.aws_endpoint_url
  aws_region       = var.aws_region
  ingress_cidrs    = var.ingress_cidrs

  tags = var.tags
}
