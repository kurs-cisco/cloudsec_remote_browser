variable "project_name" {
  description = "Project name used for tags and resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
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
  description = "Private subnets used by the standard managed node group for RBI control-plane workloads."
  type        = list(string)
}

variable "cluster_security_group_ids" {
  description = "Additional security groups attached to the EKS control plane."
  type        = list(string)
  default     = []
}

variable "endpoint_private_access" {
  description = "Enable private API endpoint access."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API endpoint access."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Explicit CIDRs allowed to reach the public API endpoint when public access is enabled. Do not use 0.0.0.0/0."
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
  default     = ["api", "audit", "authenticator"]
}

variable "authentication_mode" {
  description = "EKS access authentication mode."
  type        = string
  default     = "API_AND_CONFIG_MAP"

  validation {
    condition     = contains(["CONFIG_MAP", "API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be CONFIG_MAP, API, or API_AND_CONFIG_MAP."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Grant the Terraform caller cluster-admin access at cluster creation."
  type        = bool
  default     = true
}

variable "cluster_encryption_key_arn" {
  description = "Optional KMS key ARN for Kubernetes secret encryption."
  type        = string
  default     = ""
}

variable "ip_family" {
  description = "Kubernetes service IP family."
  type        = string
  default     = "ipv4"

  validation {
    condition     = contains(["ipv4", "ipv6"], var.ip_family)
    error_message = "ip_family must be ipv4 or ipv6."
  }
}

variable "service_ipv4_cidr" {
  description = "Optional Kubernetes service IPv4 CIDR. Leave null for the EKS default."
  type        = string
  default     = null
}

variable "cluster_addons" {
  description = "EKS managed add-ons to install with the cluster."
  type = map(object({
    addon_version            = optional(string)
    configuration_values     = optional(string)
    service_account_role_arn = optional(string)
  }))
  default = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }
}

variable "standard_node_role_name" {
  description = "IAM role name for the standard managed node group. Leave empty to derive from the cluster name."
  type        = string
  default     = ""
}

variable "standard_node_group" {
  description = "Standard EKS managed node group used for non-Kata RBI control-plane workloads."
  type = object({
    name            = optional(string, "rbi-control")
    instance_types  = optional(list(string), ["m6i.large"])
    capacity_type   = optional(string, "ON_DEMAND")
    ami_type        = optional(string, "AL2023_x86_64_STANDARD")
    min_size        = optional(number, 2)
    desired_size    = optional(number, 2)
    max_size        = optional(number, 4)
    disk_size       = optional(number, 40)
    labels          = optional(map(string), {})
    taints          = optional(list(object({ key = string, value = optional(string), effect = string })), [])
    max_unavailable = optional(number, 1)
  })
  default = {}
}

variable "tags" {
  description = "Additional tags applied to AWS resources."
  type        = map(string)
  default     = {}
}
