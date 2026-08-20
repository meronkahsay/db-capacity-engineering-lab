output "instance_id" {
  description = "EC2 instance ID (Docker-backed, on LocalStack)."
  value       = module.service.instance_id
}

output "instance_private_ip" {
  description = "Private IP of the instance — the bridge-reachable address on LocalStack."
  value       = module.service.instance_private_ip
}

output "alb_dns_name" {
  description = "ALB DNS name (declared as IaC; nginx on the instance carries the real traffic on LocalStack)."
  value       = module.service.alb_dns_name
}

output "secret_arn" {
  description = "Secrets Manager ARN of the DB credential envelope (the value itself is never output here)."
  value       = module.data.secret_arn
}

output "db_endpoint" {
  description = "DB host the app connects to (the Aiven service hostname)."
  value       = module.data.db_endpoint
}
