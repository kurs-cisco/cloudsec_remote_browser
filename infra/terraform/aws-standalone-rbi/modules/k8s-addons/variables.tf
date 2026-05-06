variable "runtime_class_name" {
  description = "RuntimeClass name used by Kata-backed RBI workers."
  type        = string
  default     = "kata-clh"
}

variable "runtime_handler" {
  description = "Containerd runtime handler registered on Kata worker nodes."
  type        = string
  default     = "kata-clh"
}

variable "runtime_overhead_cpu" {
  description = "RuntimeClass fixed pod CPU overhead."
  type        = string
  default     = "250m"
}

variable "runtime_overhead_memory" {
  description = "RuntimeClass fixed pod memory overhead."
  type        = string
  default     = "512Mi"
}

variable "node_selector" {
  description = "RuntimeClass scheduling node selector for Kata worker nodes."
  type        = map(string)
  default = {
    "cloudsec.cisco.com/rbi-worker-plane" = "true"
    "cloudsec.cisco.com/node-pool"        = "rbi-workers"
  }
}

variable "tolerations" {
  description = "RuntimeClass scheduling tolerations for the dedicated Kata node taints."
  type = list(object({
    key      = string
    operator = string
    value    = optional(string)
    effect   = string
  }))
  default = [
    {
      key      = "cloudsec.cisco.com/rbi-worker-plane"
      operator = "Equal"
      value    = "true"
      effect   = "NoSchedule"
    }
  ]
}

variable "labels" {
  description = "Additional labels applied to Kubernetes add-on resources."
  type        = map(string)
  default     = {}
}
