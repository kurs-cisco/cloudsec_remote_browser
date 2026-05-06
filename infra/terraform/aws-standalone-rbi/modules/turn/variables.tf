variable "name" {
  description = "Name prefix for TURN resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for TURN resources."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR allowed for TURN egress to internal media/control endpoints."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for TURN instances and NLB."
  type        = list(string)
}

variable "allowed_client_cidrs" {
  description = "CIDR ranges allowed to connect to TURN listener and relay ports."
  type        = list(string)
  default     = []
}

variable "bootstrap_https_egress_cidrs" {
  description = "CIDR ranges allowed for TURN host HTTPS bootstrap egress to package repositories, AWS APIs, and coturn image registries. Prefer VPC endpoints or a prebuilt AMI for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ami_id" {
  description = "Optional TURN host AMI ID. If null, Amazon Linux 2023 is selected and bootstrapped through user data."
  type        = string
  default     = null
}

variable "coturn_image" {
  description = "coturn container image pulled and run by TURN host user data."
  type        = string
  default     = "coturn/coturn:4.6"
}

variable "instance_type" {
  description = "TURN instance type."
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Optional EC2 key pair name for break-glass host access."
  type        = string
  default     = null
}

variable "turn_port" {
  description = "TURN UDP/TCP listener port."
  type        = number
  default     = 3478
}

variable "tls_port" {
  description = "Optional TURN TCP listener port exposed by the NLB for firewall traversal."
  type        = number
  default     = 443
}

variable "relay_port_min" {
  description = "Minimum UDP relay port."
  type        = number
  default     = 49152
}

variable "relay_port_max" {
  description = "Maximum UDP relay port."
  type        = number
  default     = 65535
}

variable "min_size" {
  description = "Minimum ASG size."
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Desired ASG capacity."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum ASG size."
  type        = number
  default     = 4
}

variable "root_volume_size" {
  description = "Root volume size in GiB."
  type        = number
  default     = 20
}

variable "nlb_internal" {
  description = "Whether the TURN NLB is internal."
  type        = bool
  default     = false
}

variable "internal_nlb_enabled" {
  description = "Whether to create a second internal TURN NLB for VPC-local workers."
  type        = bool
  default     = true
}

variable "internal_subnet_ids" {
  description = "Private subnet IDs for the internal worker-facing TURN NLB. Falls back to public_subnet_ids when empty."
  type        = list(string)
  default     = []
}

variable "nlb_subnet_mapping_allocation_ids" {
  description = "Optional EIP allocation IDs for static NLB addresses, one per public subnet."
  type        = list(string)
  default     = []
}

variable "additional_instance_policy_arns" {
  description = "Additional managed policy ARNs to attach to the TURN instance role."
  type        = list(string)
  default     = []
}

variable "realm" {
  description = "TURN realm advertised by coturn."
  type        = string
  default     = "turn.local"
}

variable "shared_secret_secret_id" {
  description = "Secrets Manager secret ID/name containing the TURN static auth secret JSON payload. Empty disables secret fetch wiring."
  type        = string
  default     = ""
}

variable "shared_secret_secret_arn" {
  description = "Secrets Manager secret ARN or ARN pattern for the TURN shared secret, used by the instance role policy."
  type        = string
  default     = ""
}

variable "shared_secret_json_key" {
  description = "JSON key inside the TURN shared secret payload."
  type        = string
  default     = "static_auth_secret"
}

variable "tags" {
  description = "Tags applied to TURN resources."
  type        = map(string)
  default     = {}
}
