# =============================================================================
# Root module — variables
#
# Composes the group platform's modules/data + modules/service for THIS
# individual rehost (capacity-api). Group-owned module code lives in
# regional-health-platform, sourced by pinned git ref below (main.tf) — never
# copy-pasted here.
# =============================================================================

variable "name_prefix" {
  description = "Prefix for names/tags/identifiers this root creates. Matches devops-g1-ls convention from regional-health-platform/README.md."
  type        = string
  default     = "devops-g1-ls-capacity-api"
}

variable "aws_region" {
  description = "AWS region for the provider."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags merged onto every resource this root creates."
  type        = map(string)
  default = {
    Project = "regional-health"
    Service = "capacity-api"
  }
}

# --- modules/data (Aiven MySQL + Secrets Manager) ---------------------------
# All four aiven_* values come from your own personal Aiven MySQL service's
# "Connection details" page (per the #announcements RDS->Aiven switch). None
# of them belong in a default, a committed tfvars file, or CI log — source via
# TF_VAR_* env vars (local shell / GitHub Actions repo secret), same
# discipline as LOCALSTACK_AUTH_TOKEN.

variable "db_name" {
  description = "Application database name on the Aiven service."
  type        = string
  default     = "capacity_lab"
}

variable "secret_name" {
  description = "Secrets Manager secret name holding the credential envelope."
  type        = string
  default     = "regional-health/capacity-api/db"
}

variable "aiven_host" {
  description = "Aiven MySQL service hostname. No default — always caller-supplied via TF_VAR_aiven_host."
  type        = string
}

variable "aiven_port" {
  description = "Aiven MySQL service port. No default — always caller-supplied via TF_VAR_aiven_port."
  type        = number
}

variable "aiven_username" {
  description = "Aiven MySQL admin username. Aiven's free-tier services all use avnadmin."
  type        = string
  default     = "avnadmin"
}

variable "aiven_password" {
  description = "Aiven MySQL admin password. No default — always caller-supplied via TF_VAR_aiven_password (CI secret / local env), never a tfvars file."
  type        = string
  sensitive   = true
}

# --- modules/service (EC2 + nginx + user-data + health) ---------------------

variable "app_ami_id" {
  description = "The AMI CI tags as localstack-ec2/<image_name>:ami-<sha12> (see golden-ci.yml's docker-build job)."
  type        = string
}

variable "app_port" {
  description = "Port the capacity-api app listens on inside the instance."
  type        = number
  default     = 3000
}

variable "aws_endpoint_url" {
  description = "Endpoint the app's AWS SDK targets from inside the instance. LocalStack default; set to \"\" for real AWS (same binary, no isLocalStack branch)."
  type        = string
  default     = "http://localhost.localstack.cloud:4566"
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach nginx (port 80). Default (null) scopes to the default VPC's CIDR inside modules/service — NEVER 0.0.0.0/0 outside of the deliberate trivy red-PR."
  type        = list(string)
  default     = null
}
