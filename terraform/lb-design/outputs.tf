output "alb_dns_name" {
  description = "ALB DNS name (design only — this module is never applied against LocalStack's Hobby tier)."
  value       = aws_lb.app.dns_name
}

output "target_group_arn" {
  description = "Target group ARN the ALB forwards to."
  value       = aws_lb_target_group.app.arn
}
