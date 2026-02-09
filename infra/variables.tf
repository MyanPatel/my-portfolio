variable "aws_region" {
  description = "Primary AWS region for S3/Route53 lookups"
  type        = string
  default     = "eu-west-1"
}

variable "domain_name" {
  description = "Root domain name"
  type        = string
  default     = "myanpatel.dev"
}

variable "enable_www" {
  description = "Whether to also serve www.<domain_name>"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to resources"
  type        = map(string)
  default = {
    Project = "portfolio"
    Owner   = "myan"
  }
}