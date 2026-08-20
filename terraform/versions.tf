terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Bootstrap (S3 bucket + DynamoDB lock table) is provided by the assignment,
  # not hand-written here (ASSIGNMENT.md C1). Backend config supplied via
  # `tofu init -backend-config=...` or environment, not hardcoded, so the
  # same root works against whichever bootstrap state store CI vs. local use.
  backend "s3" {}
}

# No provider "aws" block here on purpose. `tflocal` (LocalStack's terraform-
# local wrapper) injects LocalStack's endpoints/credentials automatically via
# a generated override file at apply time — a hand-written provider block
# would duplicate or conflict with that. On real AWS, plain `tofu` picks up
# credentials/region the normal way (env vars, instance profile, etc.) with
# no code change — same binary, no isLocalStack branch, matching the
# discipline modules/service's aws_endpoint_url already follows for the app
# itself. Region still needs to be set explicitly either way:
provider "aws" {
  region = var.aws_region
}
