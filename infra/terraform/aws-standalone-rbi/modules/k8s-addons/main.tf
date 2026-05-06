locals {
  runtime_class_labels = merge(
    {
      "app.kubernetes.io/name"       = "cloudsec-remote-browser"
      "app.kubernetes.io/component"  = "worker-runtime"
      "cloudsec.cisco.com/rbi-plane" = "worker"
    },
    var.labels,
  )
}

resource "kubernetes_manifest" "kata_runtime_class" {
  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name   = var.runtime_class_name
      labels = local.runtime_class_labels
    }
    handler = var.runtime_handler
    overhead = {
      podFixed = {
        cpu    = var.runtime_overhead_cpu
        memory = var.runtime_overhead_memory
      }
    }
    scheduling = {
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    }
  }
}
