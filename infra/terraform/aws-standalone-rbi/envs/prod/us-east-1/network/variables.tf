variable "project_name" {
  description = "Project name used for resource naming and tags."
  type        = string
  default     = "cloudsec-rbi"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region for this regional network root."
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Availability zones used for public, private, and data subnets."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "vpc_cidr" {
  description = "CIDR block for the RBI VPC."
  type        = string
  default     = "10.72.0.0/16"
}

variable "existing_vpc_id" {
  description = "Optional existing VPC ID to use instead of creating a dedicated RBI VPC. Intended for dev accounts where CreateVpc is blocked by SCP."
  type        = string
  default     = ""
}

variable "existing_vpc_cidr" {
  description = "CIDR block for existing_vpc_id. Required when existing_vpc_id is set."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "Existing public subnet IDs for ALB/TURN when existing_vpc_id is set."
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "Existing private/workload subnet IDs for PrivateLink/EKS consumers when existing_vpc_id is set."
  type        = list(string)
  default     = []
}

variable "existing_data_subnet_ids" {
  description = "Existing data subnet IDs for Redis when existing_vpc_id is set."
  type        = list(string)
  default     = []
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per availability zone."
  type        = list(string)
  default     = ["10.72.0.0/24", "10.72.1.0/24", "10.72.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private workload subnet CIDRs, one per availability zone."
  type        = list(string)
  default     = ["10.72.16.0/20", "10.72.32.0/20", "10.72.48.0/20"]
}

variable "data_subnet_cidrs" {
  description = "Private data subnet CIDRs, one per availability zone."
  type        = list(string)
  default     = ["10.72.96.0/24", "10.72.97.0/24", "10.72.98.0/24"]
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

variable "viewer_ingress_cidrs" {
  description = "CIDR ranges allowed to reach the viewer/control-plane ALB. Empty means no public ingress rules are created."
  type        = list(string)
  default     = []
}

variable "viewer_certificate_arn" {
  description = "Optional ACM certificate ARN for HTTPS on the viewer/control-plane ALB. Certificate provisioning is intentionally out of scope."
  type        = string
  default     = null
}

variable "public_endpoint_hostname" {
  description = "Public hostname SWG redirects browsers to for /swg/handoff and viewer traffic. Empty falls back to the ALB DNS name."
  type        = string
  default     = ""
}

variable "public_dns_hosted_zone_id" {
  description = "Optional Route53 public hosted zone ID used to create aliases for public_endpoint_hostname and turn_hostname."
  type        = string
  default     = ""
}

variable "public_endpoint_dns_hosted_zone_id" {
  description = "Optional Route53 hosted zone ID override for public_endpoint_hostname. Falls back to public_dns_hosted_zone_id when empty."
  type        = string
  default     = ""
}

variable "turn_dns_hosted_zone_id" {
  description = "Optional Route53 hosted zone ID override for turn_hostname. Falls back to public_dns_hosted_zone_id when empty."
  type        = string
  default     = ""
}

variable "dns_alias_evaluate_target_health" {
  description = "Whether Route53 aliases evaluate load balancer target health. Defaults false so DNS can be scaffolded before workloads attach."
  type        = bool
  default     = false
}

variable "privatelink_private_dns_name" {
  description = "Optional PrivateLink private DNS name for SWG bootstrap endpoint consumers."
  type        = string
  default     = null
}

variable "privatelink_allowed_principals" {
  description = "SWG AWS principals allowed to create interface endpoints to the RBI bootstrap endpoint service."
  type        = list(string)
  default     = []
}

variable "privatelink_acceptance_required" {
  description = "Require RBI account acceptance for SWG endpoint connection requests."
  type        = bool
  default     = true
}

variable "turn_client_cidrs" {
  description = "CIDR ranges allowed to reach TURN listener and relay ports. Empty means no public TURN ingress rules are created."
  type        = list(string)
  default     = []
}

variable "turn_hostname" {
  description = "Public TURN hostname. Empty falls back to the TURN NLB DNS name."
  type        = string
  default     = ""
}

variable "turn_internal_nlb_enabled" {
  description = "Whether to create an internal TURN NLB for worker-to-TURN traffic."
  type        = bool
  default     = true
}

variable "worker_turn_hostname" {
  description = "Private worker-facing TURN hostname. Empty falls back to the internal TURN NLB DNS name."
  type        = string
  default     = ""
}

variable "worker_turn_private_dns_zone_name" {
  description = "Private Route53 zone name for worker_turn_hostname when Terraform should create the zone."
  type        = string
  default     = ""
}

variable "worker_turn_private_dns_hosted_zone_id" {
  description = "Existing private Route53 hosted zone ID for worker_turn_hostname. Empty creates a private zone when worker_turn_hostname is set."
  type        = string
  default     = ""
}

variable "turn_ami_id" {
  description = "Optional pre-baked TURN AMI ID. If null, the module selects an Amazon Linux 2023 AMI as a placeholder host image."
  type        = string
  default     = null
}

variable "turn_instance_type" {
  description = "EC2 instance type for TURN hosts."
  type        = string
  default     = "t3.small"
}

variable "turn_min_size" {
  description = "Minimum number of TURN instances."
  type        = number
  default     = 2
}

variable "turn_desired_capacity" {
  description = "Desired number of TURN instances."
  type        = number
  default     = 2
}

variable "turn_max_size" {
  description = "Maximum number of TURN instances."
  type        = number
  default     = 4
}

variable "turn_nlb_eip_allocation_ids" {
  description = "Optional Elastic IP allocation IDs for static public TURN NLB addresses, one per public subnet. Empty lets AWS assign NLB addresses."
  type        = list(string)
  default     = []
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_node_count" {
  description = "Number of Redis cache nodes in the replication group."
  type        = number
  default     = 2
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "tags" {
  description = "Additional tags applied to regional resources."
  type        = map(string)
  default     = {}
}
