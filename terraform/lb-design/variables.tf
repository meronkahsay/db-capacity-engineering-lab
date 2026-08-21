variable "name_prefix" {
  description = "Prefix for resource names/tags."
  type        = string
  default     = "devops-g1-ls-capacity-api"
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = { Project = "regional-health", Service = "capacity-api" }
}
