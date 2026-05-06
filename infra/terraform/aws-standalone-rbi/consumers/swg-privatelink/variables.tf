variable "project_name" {
  description = "Project name used for resource naming and tags."
  type        = string
  default     = "cloudsec-rbi"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region of the SWG consumer VPC."
  type        = string
}

variable "name_suffix" {
  description = "Short suffix used in resource names, for example swg-usw2-dev."
  type        = string
  default     = "swg-consumer"
}

variable "vpc_id" {
  description = "SWG consumer VPC ID where the interface endpoint is created."
  type        = string
}

variable "vpc_cidr_blocks" {
  description = "CIDR blocks allowed to reach the endpoint ENIs when explicit source CIDRs are not supplied."
  type        = list(string)
}

variable "subnet_ids" {
  description = "Private subnet IDs in the SWG consumer VPC for endpoint ENIs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet_id is required."
  }
}

variable "endpoint_service_name" {
  description = "RBI provider endpoint service name, for example com.amazonaws.vpce.<region>.vpce-svc-..."
  type        = string
}

variable "private_dns_enabled" {
  description = "Enable the provider-owned PrivateLink private DNS name in this consumer VPC."
  type        = bool
  default     = true
}

variable "allowed_client_cidrs" {
  description = "Optional CIDRs allowed to connect to endpoint ENIs on TCP/443. Defaults to vpc_cidr_blocks."
  type        = list(string)
  default     = []
}

variable "allowed_client_security_group_ids" {
  description = "Optional same-VPC security groups allowed to connect to endpoint ENIs on TCP/443."
  type        = list(string)
  default     = []
}

variable "additional_endpoint_security_group_ids" {
  description = "Additional security groups to attach to the interface endpoint."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to resources."
  type        = map(string)
  default     = {}
}
