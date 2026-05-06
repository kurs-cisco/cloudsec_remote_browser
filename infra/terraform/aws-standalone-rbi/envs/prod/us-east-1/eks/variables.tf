variable "aws_region" {
  description = "AWS region for the standalone RBI EKS stack."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name used for tags and resource names."
  type        = string
  default     = "cloudsec-standalone-rbi"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "cloudsec-rbi-prod-us-east-1"
}

variable "cluster_version" {
  description = "Optional EKS Kubernetes version. Leave null to let EKS choose the account default."
  type        = string
  default     = null
}

variable "cluster_subnet_ids" {
  description = "Subnets used by the EKS control plane."
  type        = list(string)
}

variable "standard_node_subnet_ids" {
  description = "Private subnets for the standard control workload node group. Defaults to cluster_subnet_ids when empty."
  type        = list(string)
  default     = []
}

variable "kata_node_subnet_ids" {
  description = "Private subnets for the dedicated bare-metal Kata worker node group. Defaults to standard_node_subnet_ids or cluster_subnet_ids when empty."
  type        = list(string)
  default     = []
}

variable "cluster_security_group_ids" {
  description = "Additional security groups attached to the EKS control plane."
  type        = list(string)
  default     = []
}

variable "kata_security_group_ids" {
  description = "Optional security groups for the Kata launch template. Leave empty to let EKS attach the cluster security group."
  type        = list(string)
  default     = []
}

variable "endpoint_private_access" {
  description = "Enable private EKS API endpoint access."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public EKS API endpoint access."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Explicit CIDRs allowed to reach the public EKS API endpoint. Do not use 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0") && !contains(var.public_access_cidrs, "::/0")
    error_message = "public_access_cidrs must not include 0.0.0.0/0 or ::/0."
  }
}

variable "enabled_cluster_log_types" {
  description = "EKS control plane log types to enable."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_encryption_key_arn" {
  description = "Optional KMS key ARN for Kubernetes secret encryption."
  type        = string
  default     = ""
}

variable "standard_node_instance_types" {
  description = "Instance types for the standard managed node group."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "standard_node_min_size" {
  description = "Minimum standard node count."
  type        = number
  default     = 2
}

variable "standard_node_desired_size" {
  description = "Desired standard node count."
  type        = number
  default     = 2
}

variable "standard_node_max_size" {
  description = "Maximum standard node count."
  type        = number
  default     = 4
}

variable "kata_worker_ami_id" {
  description = "Custom AL2023 Kata worker AMI ID."
  type        = string
}

variable "kata_worker_instance_type" {
  description = "Fallback bare-metal instance type for Kata worker nodes when kata_worker_instance_types is empty."
  type        = string
  default     = "c5.metal"
}

variable "kata_worker_instance_types" {
  description = "Bare-metal instance types for the Kata worker Spot pool. Use x86_64 metal types while the AMI and images are amd64."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for instance_type in var.kata_worker_instance_types : can(regex("\\.metal$", instance_type))
    ])
    error_message = "kata_worker_instance_types must contain only bare-metal instance types."
  }
}

variable "kata_worker_capacity_type" {
  description = "Capacity type for the Kata worker managed node group."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.kata_worker_capacity_type)
    error_message = "kata_worker_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "kata_node_min_size" {
  description = "Minimum Kata worker node count."
  type        = number
  default     = 1
}

variable "kata_node_desired_size" {
  description = "Desired Kata worker node count."
  type        = number
  default     = 2
}

variable "kata_node_max_size" {
  description = "Maximum Kata worker node count."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Additional tags applied to AWS resources."
  type        = map(string)
  default     = {}
}
