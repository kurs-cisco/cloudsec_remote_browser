variable "app_name" {
  description = "Kubernetes app label value for RBI worker resources."
  type        = string
  default     = "cloudsec-remote-browser"
}

variable "create_control_namespace" {
  description = "Create a labeled placeholder namespace for RBI control-plane workloads so worker NetworkPolicy selectors have a target."
  type        = bool
  default     = true
}

variable "control_namespace" {
  description = "Namespace expected to host RBI control-plane services."
  type        = string
  default     = "cloudsec-rbi-control"
}

variable "worker_namespace" {
  description = "Namespace used by Kata-backed RBI workers."
  type        = string
  default     = "cloudsec-rbi-workers"
}

variable "service_account_name" {
  description = "ServiceAccount used by RBI worker pods."
  type        = string
  default     = "rbi-worker"
}

variable "runtime_class_name" {
  description = "RuntimeClass used by worker pods."
  type        = string
  default     = "kata-clh"
}

variable "worker_image" {
  description = "Worker image URI used by the pool Deployment and suspended session Job template."
  type        = string
  default     = "cloudsec-remote-browser-worker:latest"
}

variable "worker_image_pull_policy" {
  description = "Worker image pull policy."
  type        = string
  default     = "IfNotPresent"
}

variable "control_plane_image_pull_policy" {
  description = "Image pull policy for RBI control-plane services."
  type        = string
  default     = "IfNotPresent"
}

variable "control_plane_services" {
  description = "RBI control-plane Deployments and Services keyed by service name."
  type = map(object({
    image                           = string
    port                            = number
    replicas                        = optional(number, 2)
    command                         = optional(list(string), [])
    args                            = optional(list(string), [])
    env                             = optional(map(string), {})
    service_account_name            = optional(string)
    automount_service_account_token = optional(bool, false)
    readiness_path                  = optional(string, "/healthz")
    liveness_path                   = optional(string, "/healthz")
    resources = optional(object({
      requests = map(string)
      limits   = map(string)
    }))
  }))
  default = {
    runtime = {
      image                           = "cloudsec-remote-browser-control-plane:latest"
      port                            = 8080
      replicas                        = 2
      service_account_name            = "rbi-runtime"
      automount_service_account_token = true
      readiness_path                  = "/health"
      liveness_path                   = "/health"
      env = {
        WORKER_LAUNCH_MODE                   = "kubernetes"
        KUBERNETES_WORKER_NAMESPACE          = "cloudsec-rbi-workers"
        KUBERNETES_WORKER_RUNTIME_CLASS_NAME = "kata-clh"
        KUBERNETES_WORKER_CONFIG_MAP_NAME    = "rbi-worker-shared-config"
        KUBERNETES_WORKER_SERVICE_ACCOUNT    = "rbi-worker"
        IDLE_REAPER_INTERVAL_MS              = "30000"
        KUBERNETES_ORPHAN_REAPER_ENABLED     = "true"
        KUBERNETES_ORPHAN_REAPER_INTERVAL_MS = "30000"
        KUBERNETES_ORPHAN_WORKER_GRACE_MS    = "60000"
      }
    }
    session-authority = {
      image = "cloudsec-remote-browser-session-authority:latest"
      port  = 18081
      env = {
        SESSION_AUTHORITY_ADDR       = ":18081"
        SESSION_AUTHORITY_RELAY_MODE = "gateway-media-relay"
      }
    }
    media-gateway = {
      image = "cloudsec-remote-browser-media-gateway:latest"
      port  = 18082
      env = {
        MEDIA_GATEWAY_ADDR               = ":18082"
        MEDIA_GATEWAY_ENABLE_MEDIA_RELAY = "true"
        MEDIA_GATEWAY_DEFAULT_RELAY_MODE = "gateway-media-relay"
      }
    }
    file-broker = {
      image = "cloudsec-remote-browser-file-broker:latest"
      port  = 8093
      env = {
        FILE_BROKER_ADDR = ":8093"
      }
    }
    clipboard-broker = {
      image = "cloudsec-remote-browser-clipboard-broker:latest"
      port  = 8094
      env = {
        CLIPBOARD_BROKER_ADDR = ":8094"
      }
    }
  }
}

variable "control_plane_secret_env" {
  description = "Secret-backed environment variables for control-plane services. Values reference Kubernetes Secrets only; secret material must not be supplied to Terraform."
  type = map(map(object({
    secret_name = string
    key         = string
    optional    = optional(bool, false)
  })))
  default = {}
}

variable "target_group_bindings" {
  description = "AWS Load Balancer Controller TargetGroupBinding manifests keyed by Kubernetes resource name."
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

variable "control_plane_resources" {
  description = "Default resources for RBI control-plane containers."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = {
      cpu    = "250m"
      memory = "256Mi"
    }
    limits = {
      cpu    = "1"
      memory = "1Gi"
    }
  }
}

variable "worker_node_selector" {
  description = "Node selector for Kata-backed worker pods."
  type        = map(string)
  default = {
    "kubernetes.io/arch"                  = "amd64"
    "kubernetes.io/os"                    = "linux"
    "cloudsec.cisco.com/rbi-worker-plane" = "true"
    "cloudsec.cisco.com/node-pool"        = "rbi-workers"
  }
}

variable "worker_tolerations" {
  description = "Tolerations for the dedicated Kata worker node group."
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

variable "shared_config" {
  description = "Overrides for the worker shared ConfigMap."
  type        = map(string)
  default     = {}
}

variable "worker_resources" {
  description = "Resource requests and limits for worker containers."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = {
      cpu                 = "1500m"
      memory              = "3Gi"
      "ephemeral-storage" = "4Gi"
    }
    limits = {
      cpu                 = "3"
      memory              = "6Gi"
      "ephemeral-storage" = "8Gi"
    }
  }
}

variable "pool_deployment_name" {
  description = "Warm-pool Deployment template name."
  type        = string
  default     = "rbi-worker-pool-template"
}

variable "pool_replicas" {
  description = "Initial warm-pool replica count. Defaults to zero for safe apply."
  type        = number
  default     = 0
}

variable "worker_pool_hpa_enabled" {
  description = "Create a HorizontalPodAutoscaler for the warm worker pool Deployment."
  type        = bool
  default     = false
}

variable "worker_pool_hpa_min_replicas" {
  description = "Minimum warm worker pool replicas when HPA is enabled. CPU/memory HPA requires at least one replica."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_pool_hpa_min_replicas >= 1
    error_message = "worker_pool_hpa_min_replicas must be at least 1 for CPU/memory HPA."
  }
}

variable "worker_pool_hpa_max_replicas" {
  description = "Maximum warm worker pool replicas when HPA is enabled."
  type        = number
  default     = 12

  validation {
    condition     = var.worker_pool_hpa_max_replicas >= 1
    error_message = "worker_pool_hpa_max_replicas must be at least 1."
  }
}

variable "worker_pool_hpa_cpu_target_utilization" {
  description = "Average CPU utilization percentage target for the warm worker pool HPA."
  type        = number
  default     = 65

  validation {
    condition     = var.worker_pool_hpa_cpu_target_utilization >= 1 && var.worker_pool_hpa_cpu_target_utilization <= 100
    error_message = "worker_pool_hpa_cpu_target_utilization must be between 1 and 100."
  }
}

variable "worker_pool_hpa_memory_target_utilization" {
  description = "Average memory utilization percentage target for the warm worker pool HPA."
  type        = number
  default     = 75

  validation {
    condition     = var.worker_pool_hpa_memory_target_utilization >= 1 && var.worker_pool_hpa_memory_target_utilization <= 100
    error_message = "worker_pool_hpa_memory_target_utilization must be between 1 and 100."
  }
}

variable "pool_secret_name" {
  description = "Secret containing the pool shared secret."
  type        = string
  default     = "rbi-worker-pool-secret"
}

variable "pool_shared_secret_key" {
  description = "Secret key containing the pool shared secret."
  type        = string
  default     = "pool-shared-secret"
}

variable "session_job_name" {
  description = "Suspended per-session Job template name."
  type        = string
  default     = "rbi-session-worker-template"
}

variable "session_job_suspend" {
  description = "Keep the session Job template suspended until it is copied or patched for a real session."
  type        = bool
  default     = true
}

variable "session_job_active_deadline_seconds" {
  description = "Maximum runtime for a session worker Job."
  type        = number
  default     = 7200
}

variable "session_job_ttl_seconds_after_finished" {
  description = "TTL for completed session worker Jobs."
  type        = number
  default     = 3600
}

variable "session_secret_name" {
  description = "Secret containing per-session worker token and TURN credentials."
  type        = string
  default     = "rbi-session-worker-secret"
}

variable "session_id_placeholder" {
  description = "Placeholder SESSION_ID value in the suspended Job template."
  type        = string
  default     = "replace-with-session-id"
}

variable "target_url_placeholder" {
  description = "Placeholder TARGET_URL value in the suspended Job template."
  type        = string
  default     = "https://example.com/"
}

variable "tmp_size_limit" {
  description = "Memory-backed /tmp emptyDir size limit."
  type        = string
  default     = "1Gi"
}

variable "dev_shm_size_limit" {
  description = "Memory-backed /dev/shm emptyDir size limit."
  type        = string
  default     = "1Gi"
}

variable "home_size_limit" {
  description = "/home/rbi emptyDir size limit."
  type        = string
  default     = "6Gi"
}

variable "enable_public_egress" {
  description = "Dev-only rollback: allow worker egress to public IP space after denying RFC1918 and IMDS ranges. Production RBI should leave this false and force public web access through the SWG proxy path."
  type        = bool
  default     = false
}

variable "public_egress_cidr" {
  description = "Public egress CIDR used by the worker NetworkPolicy."
  type        = string
  default     = "0.0.0.0/0"
}

variable "public_egress_except_cidrs" {
  description = "CIDRs excluded from the public egress NetworkPolicy rule."
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.169.254/32"]
}

variable "labels" {
  description = "Additional labels applied to RBI app resources."
  type        = map(string)
  default     = {}
}
