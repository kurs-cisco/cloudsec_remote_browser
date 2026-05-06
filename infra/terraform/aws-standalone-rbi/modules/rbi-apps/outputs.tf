output "control_namespace" {
  description = "RBI control namespace."
  value       = var.control_namespace
}

output "control_service_names" {
  description = "ClusterIP service names for RBI control-plane services."
  value       = { for service_key, service in kubernetes_manifest.control_service : service_key => service.manifest.metadata.name }
}

output "control_deployment_names" {
  description = "Deployment names for RBI control-plane services."
  value       = { for service_key, deployment in kubernetes_manifest.control_deployment : service_key => deployment.manifest.metadata.name }
}

output "target_group_binding_names" {
  description = "TargetGroupBinding resource names keyed by logical binding key."
  value       = { for binding_key, binding in kubernetes_manifest.target_group_binding : binding_key => binding.manifest.metadata.name }
}

output "secret_provider_class_names" {
  description = "SecretProviderClass resource names keyed by logical class key."
  value       = { for class_key, secret_provider_class in kubernetes_manifest.secret_provider_class : class_key => secret_provider_class.manifest.metadata.name }
}

output "worker_namespace" {
  description = "RBI worker namespace."
  value       = var.worker_namespace
}

output "service_account_name" {
  description = "RBI worker ServiceAccount name."
  value       = var.service_account_name
}

output "worker_pool_deployment_name" {
  description = "Warm-pool Deployment template name."
  value       = var.pool_deployment_name
}

output "session_worker_job_name" {
  description = "Suspended session worker Job template name."
  value       = var.session_job_name
}
