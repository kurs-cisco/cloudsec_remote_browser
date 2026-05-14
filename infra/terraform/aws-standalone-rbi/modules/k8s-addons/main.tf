locals {
  runtime_class_labels = merge(
    {
      "app.kubernetes.io/name"       = "cloudsec-remote-browser"
      "app.kubernetes.io/component"  = "worker-runtime"
      "cloudsec.cisco.com/rbi-plane" = "worker"
    },
    var.labels,
  )

  metrics_server_labels = merge(
    {
      "app.kubernetes.io/name"      = "metrics-server"
      "app.kubernetes.io/component" = "metrics-server"
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

resource "kubernetes_manifest" "metrics_server_service_account" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "metrics-server"
      namespace = "kube-system"
      labels    = local.metrics_server_labels
    }
  }
}

resource "kubernetes_manifest" "metrics_server_cluster_role" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name   = "system:metrics-server"
      labels = local.metrics_server_labels
    }
    rules = [
      {
        apiGroups = [""]
        resources = ["nodes/metrics"]
        verbs     = ["get"]
      },
      {
        apiGroups = [""]
        resources = ["pods", "nodes"]
        verbs     = ["get", "list", "watch"]
      },
    ]
  }
}

resource "kubernetes_manifest" "metrics_server_aggregated_reader_cluster_role" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "system:aggregated-metrics-reader"
      labels = merge(local.metrics_server_labels, {
        "rbac.authorization.k8s.io/aggregate-to-admin" = "true"
        "rbac.authorization.k8s.io/aggregate-to-edit"  = "true"
        "rbac.authorization.k8s.io/aggregate-to-view"  = "true"
      })
    }
    rules = [
      {
        apiGroups = ["metrics.k8s.io"]
        resources = ["pods", "nodes"]
        verbs     = ["get", "list", "watch"]
      },
    ]
  }
}

resource "kubernetes_manifest" "metrics_server_cluster_role_binding" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name   = "system:metrics-server"
      labels = local.metrics_server_labels
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "system:metrics-server"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "metrics-server"
        namespace = "kube-system"
      },
    ]
  }

  depends_on = [
    kubernetes_manifest.metrics_server_cluster_role,
    kubernetes_manifest.metrics_server_service_account,
  ]
}

resource "kubernetes_manifest" "metrics_server_auth_reader_role_binding" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "metrics-server-auth-reader"
      namespace = "kube-system"
      labels    = local.metrics_server_labels
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "extension-apiserver-authentication-reader"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "metrics-server"
        namespace = "kube-system"
      },
    ]
  }

  depends_on = [kubernetes_manifest.metrics_server_service_account]
}

resource "kubernetes_manifest" "metrics_server_auth_delegator_cluster_role_binding" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name   = "metrics-server:system:auth-delegator"
      labels = local.metrics_server_labels
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "system:auth-delegator"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "metrics-server"
        namespace = "kube-system"
      },
    ]
  }

  depends_on = [kubernetes_manifest.metrics_server_service_account]
}

resource "kubernetes_manifest" "metrics_server_service" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "metrics-server"
      namespace = "kube-system"
      labels    = local.metrics_server_labels
    }
    spec = {
      selector = {
        "app.kubernetes.io/name" = "metrics-server"
      }
      ports = [
        {
          name       = "https"
          port       = 443
          protocol   = "TCP"
          targetPort = "https"
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "metrics_server_deployment" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "metrics-server"
      namespace = "kube-system"
      labels    = local.metrics_server_labels
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "metrics-server"
        }
      }
      template = {
        metadata = {
          labels = local.metrics_server_labels
        }
        spec = {
          serviceAccountName = "metrics-server"
          containers = [
            {
              name            = "metrics-server"
              image           = var.metrics_server_image
              imagePullPolicy = "IfNotPresent"
              args = [
                "--cert-dir=/tmp",
                "--secure-port=10250",
                "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
                "--kubelet-use-node-status-port",
                "--kubelet-insecure-tls",
                "--metric-resolution=15s",
              ]
              ports = [
                {
                  name          = "https"
                  containerPort = 10250
                  protocol      = "TCP"
                },
              ]
              resources = {
                requests = {
                  cpu    = "100m"
                  memory = "200Mi"
                }
                limits = {
                  cpu    = "250m"
                  memory = "400Mi"
                }
              }
              readinessProbe = {
                httpGet = {
                  path   = "/readyz"
                  port   = "https"
                  scheme = "HTTPS"
                }
                periodSeconds = 10
              }
              livenessProbe = {
                httpGet = {
                  path   = "/livez"
                  port   = "https"
                  scheme = "HTTPS"
                }
                periodSeconds = 10
              }
              securityContext = {
                allowPrivilegeEscalation = false
                capabilities = {
                  drop = ["ALL"]
                }
                readOnlyRootFilesystem = true
                runAsNonRoot           = true
                runAsUser              = 1000
                seccompProfile = {
                  type = "RuntimeDefault"
                }
              }
              volumeMounts = [
                {
                  name      = "tmp"
                  mountPath = "/tmp"
                },
              ]
            },
          ]
          nodeSelector = {
            "kubernetes.io/os" = "linux"
          }
          priorityClassName = "system-cluster-critical"
          volumes = [
            {
              name     = "tmp"
              emptyDir = {}
            },
          ]
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.metrics_server_cluster_role_binding,
    kubernetes_manifest.metrics_server_auth_reader_role_binding,
    kubernetes_manifest.metrics_server_auth_delegator_cluster_role_binding,
  ]
}

resource "kubernetes_manifest" "metrics_server_api_service" {
  count = var.enable_metrics_server ? 1 : 0

  manifest = {
    apiVersion = "apiregistration.k8s.io/v1"
    kind       = "APIService"
    metadata = {
      name   = "v1beta1.metrics.k8s.io"
      labels = local.metrics_server_labels
    }
    spec = {
      group                 = "metrics.k8s.io"
      groupPriorityMinimum  = 100
      insecureSkipTLSVerify = true
      service = {
        name      = "metrics-server"
        namespace = "kube-system"
      }
      version         = "v1beta1"
      versionPriority = 100
    }
  }

  depends_on = [
    kubernetes_manifest.metrics_server_service,
    kubernetes_manifest.metrics_server_deployment,
  ]
}
