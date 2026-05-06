variable "name" {
  description = "Name prefix for ingress resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for ingress resources."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR used to constrain load balancer and service egress."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the application load balancer."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the SWG bootstrap PrivateLink NLB."
  type        = list(string)
  default     = []
}

variable "allowed_ingress_cidrs" {
  description = "CIDR ranges allowed to reach the ALB. Empty creates no ingress rules."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "Optional ACM certificate ARN for HTTPS. Certificate creation is out of scope."
  type        = string
  default     = null
}

variable "enable_http_redirect" {
  description = "Whether HTTP redirects to HTTPS when certificate_arn is set."
  type        = bool
  default     = true
}

variable "internal" {
  description = "Whether the ALB is internal."
  type        = bool
  default     = false
}

variable "alb_access_logs_bucket" {
  description = "Optional S3 bucket for ALB access logs. When empty, access logging is disabled."
  type        = string
  default     = ""
}

variable "alb_access_logs_prefix" {
  description = "S3 prefix for ALB access logs when alb_access_logs_bucket is set."
  type        = string
  default     = "rbi-alb"
}

variable "alb_access_logs_enabled" {
  description = "Whether to enable ALB access logs when alb_access_logs_bucket is set."
  type        = bool
  default     = true
}

variable "public_hostname" {
  description = "Optional public hostname to alias to the RBI ALB. No DNS record is created when empty."
  type        = string
  default     = ""
}

variable "public_hosted_zone_id" {
  description = "Optional Route53 hosted zone ID used to create an A alias for public_hostname."
  type        = string
  default     = ""
}

variable "privatelink_private_dns_hosted_zone_id" {
  description = "Optional Route53 hosted zone ID used to create the PrivateLink private DNS verification TXT record."
  type        = string
  default     = ""
}

variable "dns_alias_evaluate_target_health" {
  description = "Whether Route53 aliases evaluate ALB target health. Defaults false so scaffold aliases resolve before targets are registered."
  type        = bool
  default     = false
}

variable "target_groups" {
  description = "Target groups for future service attachments."
  type = map(object({
    port                 = number
    protocol             = string
    target_type          = optional(string, "ip")
    health_check_path    = optional(string, "/")
    health_check_matcher = optional(string, "200-399")
    deregistration_delay = optional(number, 30)
  }))
  default = {}
}

variable "default_target_group_key" {
  description = "Target group key used as the ALB default forward target. Empty keeps the fixed 404 response."
  type        = string
  default     = ""
}

variable "listener_rules" {
  description = "Optional HTTPS listener rules keyed by rule name. Rules are ignored when no certificate is configured."
  type = map(object({
    priority         = number
    target_group_key = string
    path_patterns    = optional(list(string), [])
    host_headers     = optional(list(string), [])
  }))
  default = {}
}

variable "enable_privatelink_bootstrap" {
  description = "Whether to create the private NLB and endpoint service for SWG bootstrap traffic."
  type        = bool
  default     = true
}

variable "bootstrap_nlb_cross_zone_enabled" {
  description = "Enable cross-zone load balancing on the SWG bootstrap NLB."
  type        = bool
  default     = true
}

variable "bootstrap_port" {
  description = "Backend port for POST /api/swg/sessions on the RBI control plane."
  type        = number
  default     = 8080
}

variable "bootstrap_health_check_path" {
  description = "HTTP health check path for the PrivateLink bootstrap target group."
  type        = string
  default     = "/health"
}

variable "privatelink_acceptance_required" {
  description = "Require RBI-side acceptance for endpoint connections."
  type        = bool
  default     = true
}

variable "privatelink_allowed_principals" {
  description = "AWS principals allowed to create endpoints to the RBI bootstrap service."
  type        = list(string)
  default     = []
}

variable "privatelink_private_dns_name" {
  description = "Optional private DNS name associated with the endpoint service after domain ownership validation."
  type        = string
  default     = null
}

variable "privatelink_source_cidrs" {
  description = "CIDRs allowed to reach the bootstrap backend from the private NLB path."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to ingress resources."
  type        = map(string)
  default     = {}
}
