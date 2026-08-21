# =============================================================================
# lb-design — ALB topology as IaC only, never applied.
#
# Per Rob's 2026-08-21 clarification: ELBv2 (ALB) is a Base+ LocalStack
# feature, same tier gate as Docker-backed EC2. This is graded as IaC --
# written, validated (`tofu validate`), and scanned (trivy/zizmor) -- but
# deliberately never `tofu apply`'d. nginx on the app instance carries the
# real traffic and does the real readiness gating (see terraform/main.tf's
# module.service); this design shows the production-real front door this
# lab would use on a real-AWS or LocalStack Base+ deployment.
#
# Pattern matches regional-health-platform's modules/service ALB block
# exactly (same resource shapes, same trivy suppressions with the same
# justifications) -- kept in sync deliberately, not duplicated by accident.
# =============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Standalone SG for the ALB design (the real app instance's SG lives in
# modules/service and is not shared here -- this module is never applied,
# so no cross-resource reference to a real running instance is needed).
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-lb-design-sg"
  description = "ALB ingress (IaC design only, never applied)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from the internet, matching a public entrypoint's real posture"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the app fleet on port 80 (nginx's readiness-gated port)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-lb-design-sg" })
}

#trivy:ignore:AVD-AWS-0053 internet-facing is the intended design for a public entrypoint
resource "aws_lb" "app" {
  name                       = "${var.name_prefix}-lb-design"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = slice(data.aws_subnets.default.ids, 0, min(2, length(data.aws_subnets.default.ids)))
  drop_invalid_header_fields = true # AWS-0052

  tags = merge(var.tags, { Name = "${var.name_prefix}-lb-design" })
}

resource "aws_lb_target_group" "app" {
  name = "${var.name_prefix}-lb-design-tg"
  # Target nginx (80), not the app port directly, matching modules/service's
  # design: the LB path also goes through the readiness gate.
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    path                = "/readyz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-lb-design-tg" })
}

# HTTP (not HTTPS) accepted for this lab -- see modules/service's identical
# suppression rationale: no TLS material in the lab, nginx terminates the
# only real traffic. Production would add ACM + a 443 listener + redirect.
#trivy:ignore:AVD-AWS-0054 ALB is non-routing IaC only; no TLS material in lab; nginx terminates real traffic
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
