variable "aws_region" {
  description = "AWS region for the standalone RBI Kubernetes app root."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name used for labels and tags."
  type        = string
  default     = "cloudsec-standalone-rbi"
}

variable "cluster_name" {
  description = "Existing EKS cluster name created by the sibling eks root."
  type        = string
  default     = "cloudsec-rbi-prod-us-east-1"
}

variable "runtime_class_name" {
  description = "Kata RuntimeClass name."
  type        = string
  default     = "kata-clh"
}

variable "worker_image" {
  description = "Worker image URI."
  type        = string
  default     = "cloudsec-remote-browser-worker:latest"
}

variable "runtime_image" {
  description = "Node runtime/control-plane image URI."
  type        = string
  default     = "cloudsec-remote-browser-control-plane:latest"
}

variable "session_authority_image" {
  description = "Session Authority image URI."
  type        = string
  default     = "cloudsec-remote-browser-session-authority:latest"
}

variable "media_gateway_image" {
  description = "Media gateway image URI."
  type        = string
  default     = "cloudsec-remote-browser-media-gateway:latest"
}

variable "file_broker_image" {
  description = "File broker image URI."
  type        = string
  default     = "cloudsec-remote-browser-file-broker:latest"
}

variable "clipboard_broker_image" {
  description = "Clipboard broker image URI."
  type        = string
  default     = "cloudsec-remote-browser-clipboard-broker:latest"
}

variable "control_plane_replicas" {
  description = "Replica count for each RBI control-plane service."
  type        = number
  default     = 2
}

variable "media_gateway_replicas" {
  description = "Replica count for the media-gateway service. Multi-replica requires Redis-backed session owner routing."
  type        = number
  default     = null
}

variable "runtime_secret_name" {
  description = "Kubernetes Secret containing runtime TOKEN_SECRET, TURN_SHARED_SECRET, SWG_SHARED_SECRET, RBI_INTERNAL_SHARED_SECRET, and POOL_WORKER_SECRET values."
  type        = string
  default     = "rbi-runtime-secret"
}

variable "redis_url" {
  description = "Redis URL used by the runtime for session store, signaling bus, worker-pool store, and worker-pool bus. Leave empty to use runtime defaults."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_key_prefix" {
  description = "Redis key prefix for RBI runtime state."
  type        = string
  default     = "cloudsec-rbi"
}

variable "require_redis_backends" {
  description = "Require the runtime to use Redis-backed production stores instead of in-memory stores."
  type        = bool
  default     = false
}

variable "public_endpoint_hostname" {
  description = "Public RBI viewer/control-plane hostname."
  type        = string
  default     = ""
}

variable "turn_hostname" {
  description = "Public TURN hostname advertised to viewers."
  type        = string
  default     = ""
}

variable "worker_turn_hostname" {
  description = "Worker-reachable TURN hostname or address. Leave empty to use turn_hostname."
  type        = string
  default     = ""
}

variable "public_turn_tls_port" {
  description = "Public TURN TCP/TLS listener port used for firewall traversal."
  type        = number
  default     = 443
}

variable "control_plane_target_group_arns" {
  description = "ALB target group ARNs from the network root. Key control-plane binds to runtime; key media-gateway binds to media-gateway."
  type        = map(string)
  default     = {}
}

variable "bootstrap_target_group_arn" {
  description = "PrivateLink bootstrap NLB target group ARN from the network root. Empty disables the bootstrap TargetGroupBinding."
  type        = string
  default     = ""
}

variable "service_target_ingress_cidrs" {
  description = "CIDR ranges allowed to reach RBI pod/service target ports on the EKS cluster security group. Use the RBI VPC CIDR for ALB/NLB health checks and traffic; do not use 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "target_group_bindings" {
  description = "Additional AWS Load Balancer Controller TargetGroupBinding manifests keyed by Kubernetes resource name."
  type = map(object({
    target_group_arn = string
    service_name     = string
    service_port     = number
    target_type      = optional(string, "ip")
    labels           = optional(map(string), {})
    annotations      = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for binding_key in keys(var.target_group_bindings) :
      length(binding_key) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", binding_key))
    ])
    error_message = "TargetGroupBinding keys must be valid Kubernetes DNS labels no longer than 63 characters."
  }
}

variable "secret_provider_classes" {
  description = "Secrets Store CSI SecretProviderClass manifests keyed by Kubernetes resource name. Values identify external secret objects only; secret material must not be supplied."
  type = map(object({
    namespace   = optional(string)
    provider    = optional(string, "aws")
    parameters  = optional(map(string), {})
    labels      = optional(map(string), {})
    annotations = optional(map(string), {})
    secret_objects = optional(list(object({
      secret_name = string
      type        = optional(string, "Opaque")
      labels      = optional(map(string), {})
      annotations = optional(map(string), {})
      data = list(object({
        object_name = string
        key         = string
      }))
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for class_key in keys(var.secret_provider_classes) :
      length(class_key) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", class_key))
    ])
    error_message = "SecretProviderClass keys must be valid Kubernetes DNS labels no longer than 63 characters."
  }
}

variable "control_namespace" {
  description = "RBI control-plane namespace."
  type        = string
  default     = "cloudsec-rbi-control"
}

variable "worker_namespace" {
  description = "RBI worker namespace."
  type        = string
  default     = "cloudsec-rbi-workers"
}

variable "create_control_namespace" {
  description = "Create a labeled placeholder control namespace for worker NetworkPolicy selectors."
  type        = bool
  default     = true
}

variable "worker_shared_config" {
  description = "Overrides for the worker shared ConfigMap."
  type        = map(string)
  default     = {}
}

variable "pool_replicas" {
  description = "Initial warm-pool Deployment replica count. Defaults to zero for safe apply."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Additional AWS tags and Kubernetes labels."
  type        = map(string)
  default     = {}
}
