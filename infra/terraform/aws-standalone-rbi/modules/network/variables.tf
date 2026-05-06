variable "name" {
  description = "Name prefix for VPC resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones used by subnet tiers."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per availability zone."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private workload subnet CIDRs, one per availability zone."
  type        = list(string)
}

variable "data_subnet_cidrs" {
  description = "Private data subnet CIDRs, one per availability zone."
  type        = list(string)
}

variable "enable_dns_hostnames" {
  description = "Whether DNS hostnames are enabled on the VPC."
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Whether DNS support is enabled on the VPC."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Whether private workload subnets receive default egress through NAT gateways."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Whether to use one NAT gateway instead of one per availability zone."
  type        = bool
  default     = false
}

variable "enable_s3_gateway_endpoint" {
  description = "Whether to create an S3 gateway VPC endpoint for private and data route tables."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "AWS interface endpoint service short names to create in private subnets."
  type        = set(string)
  default     = ["ecr.api", "ecr.dkr", "logs", "ssm", "ssmmessages", "ec2messages"]
}

variable "tags" {
  description = "Tags applied to network resources."
  type        = map(string)
  default     = {}
}
