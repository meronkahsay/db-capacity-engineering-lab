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
  # Pinned to regional-health-platform@main as of 2026-08-18 (after the
  # RDS->Aiven switch, service hardening, and golden-ci Aiven-secrets fix).
  # Update this SHA (and re-run `tofu plan`) when a group module change needs
  # picking up here.
  platform_ref = "c95c942fc72ef7018399118305f3d90a9ecb524a"
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

  aws_endpoint_url = var.aws_endpoint_url
  aws_region       = var.aws_region
  ingress_cidrs    = var.ingress_cidrs

  tags = var.tags
}
