variable "project_name" {
  description = "Project name used for tags and resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API endpoint used by AL2023 nodeadm."
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster certificate authority data used by AL2023 nodeadm."
  type        = string
}

variable "service_ipv4_cidr" {
  description = "Kubernetes service IPv4 CIDR used by AL2023 nodeadm."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets used by the dedicated Kata managed node group."
  type        = list(string)
}

variable "node_group_name" {
  description = "EKS managed node group name for Kata-backed RBI workers."
  type        = string
  default     = "rbi-workers"
}

variable "ami_id" {
  description = "Custom AL2023 AMI ID with Kata, Cloud Hypervisor, and the host bootstrap script baked in."
  type        = string
}

variable "instance_type" {
  description = "Fallback bare-metal instance type used by the Kata worker node group when instance_types is empty."
  type        = string
  default     = "c5.metal"
}

variable "instance_types" {
  description = "Bare-metal instance types used by the Kata worker node group. Use multiple x86_64 metal types with SPOT to improve capacity."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for instance_type in var.instance_types : can(regex("\\.metal$", instance_type))
    ])
    error_message = "instance_types must contain only bare-metal instance types."
  }
}

variable "capacity_type" {
  description = "EKS node group capacity type."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "desired_size" {
  description = "Desired Kata worker node count."
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum Kata worker node count."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum Kata worker node count."
  type        = number
  default     = 10
}

variable "max_unavailable" {
  description = "Maximum unavailable nodes during managed node group updates."
  type        = number
  default     = 1
}

variable "node_labels" {
  description = "Labels registered by kubelet and EKS for Kata worker nodes."
  type        = map(string)
  default = {
    "cloudsec.cisco.com/rbi-worker-plane" = "true"
    "cloudsec.cisco.com/node-pool"        = "rbi-workers"
  }
}

variable "node_taints" {
  description = "Taints registered by kubelet and EKS for Kata worker nodes. Effects use AWS EKS enum values."
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = [
    {
      key    = "cloudsec.cisco.com/rbi-worker-plane"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  ]
}

variable "runtime_class_name" {
  description = "Kata RuntimeClass name expected by worker pods."
  type        = string
  default     = "kata-clh"
}

variable "expected_runtime_types" {
  description = "Containerd runtime types the host bootstrap script must find."
  type        = list(string)
  default     = ["io.containerd.kata-clh.v2", "io.containerd.kata.v2"]
}

variable "host_bootstrap_script_path" {
  description = "Path baked into the custom AMI for the Kata host bootstrap script."
  type        = string
  default     = "/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh"
}

variable "root_device_name" {
  description = "Root block device name for the custom AL2023 AMI."
  type        = string
  default     = "/dev/xvda"
}

variable "root_volume_size_gib" {
  description = "Root volume size in GiB."
  type        = number
  default     = 80
}

variable "root_volume_iops" {
  description = "Root gp3 volume IOPS."
  type        = number
  default     = 6000
}

variable "root_volume_throughput" {
  description = "Root gp3 volume throughput in MiB/s."
  type        = number
  default     = 500
}

variable "security_group_ids" {
  description = "Optional security groups to place in the launch template. Leave empty to let EKS attach the cluster security group."
  type        = list(string)
  default     = []
}

variable "create_node_role" {
  description = "Create a dedicated IAM role for the Kata managed node group."
  type        = bool
  default     = true
}

variable "node_role_arn" {
  description = "Existing node IAM role ARN when create_node_role is false."
  type        = string
  default     = ""
}

variable "node_role_name" {
  description = "IAM role name for the Kata node group. Leave empty to derive from the cluster and node group names."
  type        = string
  default     = ""
}

variable "force_update_version" {
  description = "Force node group version updates when pods cannot drain cleanly."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to AWS resources."
  type        = map(string)
  default     = {}
}
