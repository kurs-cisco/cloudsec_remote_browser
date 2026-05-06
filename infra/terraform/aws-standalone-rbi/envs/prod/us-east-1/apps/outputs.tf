output "runtime_class_name" {
  description = "RuntimeClass created for Kata workers."
  value       = module.k8s_addons.runtime_class_name
}

output "control_namespace" {
  description = "RBI control namespace."
  value       = module.rbi_apps.control_namespace
}

output "control_service_names" {
  description = "ClusterIP service names for RBI control-plane services."
  value       = module.rbi_apps.control_service_names
}

output "control_deployment_names" {
  description = "Deployment names for RBI control-plane services."
  value       = module.rbi_apps.control_deployment_names
}

output "target_group_binding_names" {
  description = "TargetGroupBinding resource names keyed by logical binding key."
  value       = module.rbi_apps.target_group_binding_names
}

output "secret_provider_class_names" {
  description = "SecretProviderClass resource names keyed by logical class key."
  value       = module.rbi_apps.secret_provider_class_names
}

output "worker_namespace" {
  description = "RBI worker namespace."
  value       = module.rbi_apps.worker_namespace
}

output "worker_pool_deployment_name" {
  description = "Warm-pool Deployment template name."
  value       = module.rbi_apps.worker_pool_deployment_name
}

output "session_worker_job_name" {
  description = "Suspended session worker Job template name."
  value       = module.rbi_apps.session_worker_job_name
}
