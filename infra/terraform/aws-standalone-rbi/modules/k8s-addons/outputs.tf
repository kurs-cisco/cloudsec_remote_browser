output "runtime_class_name" {
  description = "RuntimeClass name created by this module."
  value       = var.runtime_class_name
}

output "runtime_handler" {
  description = "Containerd runtime handler used by the RuntimeClass."
  value       = var.runtime_handler
}
