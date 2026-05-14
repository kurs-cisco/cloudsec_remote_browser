locals {
  base_labels = merge(
    {
      "app.kubernetes.io/name"       = var.app_name
      "cloudsec.cisco.com/rbi-plane" = "worker"
    },
    var.labels,
  )

  control_namespace_labels = merge(
    {
      "cloudsec.cisco.com/rbi-plane" = "control"
    },
    var.labels,
  )

  worker_namespace_labels = merge(
    {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "cloudsec.cisco.com/rbi-plane"       = "worker"
    },
    var.labels,
  )

  shared_config = merge(
    {
      POOL_WS_URL                = "ws://runtime.${var.control_namespace}.svc.cluster.local:8080/ws/pool"
      POOL_WS_CONNECT_HOST       = ""
      SIGNALING_URL              = "ws://runtime.${var.control_namespace}.svc.cluster.local:8080/ws/worker"
      SIGNALING_CONNECT_HOST     = ""
      WORKER_ICE_URLS            = "turn:turn.cloudsec-rbi-media.svc.cluster.local:3478?transport=udp,turn:turn.cloudsec-rbi-media.svc.cluster.local:3478?transport=tcp"
      WORKER_RUNTIME_CLASS       = var.runtime_class_name
      WORKER_MEDIA_MODE          = "gateway-webrtc-relay"
      WORKER_IMAGE_DIGEST        = var.worker_image
      POOL_RECYCLE_AFTER_SESSION = "1"
      ALLOWED_CANDIDATE_TYPES    = "relay"
      SWG_EGRESS_PROXY_URL       = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      HTTP_PROXY                 = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      HTTPS_PROXY                = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      ALL_PROXY                  = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      NO_PROXY                   = "localhost,127.0.0.1,::1,.svc,.svc.cluster.local,kubernetes.default.svc,runtime.${var.control_namespace}.svc.cluster.local,media-gateway.cloudsec-rbi-media.svc.cluster.local,turn.cloudsec-rbi-media.svc.cluster.local"
      http_proxy                 = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      https_proxy                = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      all_proxy                  = "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"
      no_proxy                   = "localhost,127.0.0.1,::1,.svc,.svc.cluster.local,kubernetes.default.svc,runtime.${var.control_namespace}.svc.cluster.local,media-gateway.cloudsec-rbi-media.svc.cluster.local,turn.cloudsec-rbi-media.svc.cluster.local"
      DISPLAY_WIDTH              = "1920"
      DISPLAY_HEIGHT             = "1080"
      CAPTURE_FRAMERATE          = "20"
      VIDEO_CODEC_PREFERENCES    = "VP8"
      VIDEO_MIN_BITRATE_BPS      = "600000"
      VIDEO_START_BITRATE_BPS    = "1500000"
      VIDEO_MAX_BITRATE_BPS      = "3000000"
      HOME                       = "/home/rbi"
    },
    var.shared_config,
  )

  worker_security_context = {
    fsGroup             = 1000
    fsGroupChangePolicy = "OnRootMismatch"
    runAsNonRoot        = true
    runAsGroup          = 1000
    runAsUser           = 1000
    seccompProfile = {
      type = "RuntimeDefault"
    }
  }

  container_security_context = {
    allowPrivilegeEscalation = false
    capabilities = {
      drop = ["ALL"]
    }
    readOnlyRootFilesystem = true
  }

  volume_mounts = [
    {
      name      = "tmp"
      mountPath = "/tmp"
    },
    {
      name      = "dev-shm"
      mountPath = "/dev/shm"
    },
    {
      name      = "home"
      mountPath = "/home/rbi"
    },
  ]

  volumes = [
    {
      name = "tmp"
      emptyDir = {
        medium    = "Memory"
        sizeLimit = var.tmp_size_limit
      }
    },
    {
      name = "dev-shm"
      emptyDir = {
        medium    = "Memory"
        sizeLimit = var.dev_shm_size_limit
      }
    },
    {
      name = "home"
      emptyDir = {
        sizeLimit = var.home_size_limit
      }
    },
  ]

  pool_selector_labels = {
    "app.kubernetes.io/name"      = var.app_name
    "app.kubernetes.io/component" = "rbi-worker-pool"
  }

  session_labels = merge(local.base_labels, {
    "app.kubernetes.io/component" = "rbi-session-worker"
  })

  control_plane_services = {
    for service_key, service in var.control_plane_services :
    service_key => {
      image                           = service.image
      port                            = service.port
      replicas                        = service.replicas
      command                         = service.command
      args                            = service.args
      env                             = service.env
      service_account_name            = coalesce(service.service_account_name, service_key)
      automount_service_account_token = service.automount_service_account_token
      readiness_path                  = service.readiness_path
      liveness_path                   = service.liveness_path
      resources                       = coalesce(service.resources, var.control_plane_resources)
    }
  }

  control_plane_env = {
    for service_key, service in local.control_plane_services :
    service_key => [
      for name, value in service.env : {
        name  = name
        value = value
      }
    ]
  }

  control_plane_secret_env = {
    for service_key, secret_env in var.control_plane_secret_env :
    service_key => [
      for name, ref in secret_env : {
        name = name
        valueFrom = {
          secretKeyRef = {
            name     = ref.secret_name
            key      = ref.key
            optional = ref.optional
          }
        }
      }
    ]
  }

  control_plane_selectors = {
    for service_key, service in local.control_plane_services :
    service_key => {
      "app.kubernetes.io/name"       = var.app_name
      "app.kubernetes.io/component"  = service_key
      "cloudsec.cisco.com/rbi-plane" = "control"
    }
  }

  runtime_service_account_name = contains(keys(local.control_plane_services), "runtime") ? local.control_plane_services["runtime"].service_account_name : "rbi-runtime"

  target_group_bindings = {
    for binding_key, binding in var.target_group_bindings :
    binding_key => binding
    if binding.target_group_arn != ""
  }

  secret_provider_classes = {
    for class_key, secret_provider_class in var.secret_provider_classes :
    class_key => merge(secret_provider_class, {
      namespace = coalesce(secret_provider_class.namespace, var.worker_namespace)
    })
  }
}

resource "kubernetes_manifest" "control_namespace" {
  count = var.create_control_namespace ? 1 : 0

  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = var.control_namespace
      labels = local.control_namespace_labels
    }
  }
}

resource "kubernetes_manifest" "worker_namespace" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = var.worker_namespace
      labels = local.worker_namespace_labels
    }
  }
}

resource "kubernetes_manifest" "control_service_account" {
  for_each = local.control_plane_services

  manifest = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = each.value.service_account_name
      namespace = var.control_namespace
      labels = merge(local.control_namespace_labels, {
        "app.kubernetes.io/name"      = var.app_name
        "app.kubernetes.io/component" = each.key
      })
    }
    automountServiceAccountToken = each.value.automount_service_account_token
  }

  depends_on = [kubernetes_manifest.control_namespace]
}

resource "kubernetes_manifest" "runtime_worker_role" {
  count = contains(keys(local.control_plane_services), "runtime") ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata = {
      name      = "rbi-runtime-worker-allocator"
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "runtime-worker-allocator"
      })
    }
    rules = [
      {
        apiGroups = ["batch"]
        resources = ["jobs"]
        verbs     = ["create", "get", "list", "watch", "delete", "patch", "update"]
      },
      {
        apiGroups = [""]
        resources = ["pods"]
        verbs     = ["get", "list", "watch"]
      },
    ]
  }

  depends_on = [kubernetes_manifest.worker_namespace]
}

resource "kubernetes_manifest" "runtime_worker_role_binding" {
  count = contains(keys(local.control_plane_services), "runtime") ? 1 : 0

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata = {
      name      = "rbi-runtime-worker-allocator"
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "runtime-worker-allocator"
      })
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = local.runtime_service_account_name
        namespace = var.control_namespace
      },
    ]
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "Role"
      name     = "rbi-runtime-worker-allocator"
    }
  }

  depends_on = [
    kubernetes_manifest.control_service_account,
    kubernetes_manifest.runtime_worker_role,
  ]
}

resource "kubernetes_manifest" "control_deployment" {
  for_each = local.control_plane_services

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = each.key
      namespace = var.control_namespace
      labels    = merge(local.control_namespace_labels, local.control_plane_selectors[each.key])
    }
    spec = {
      replicas = each.value.replicas
      selector = {
        matchLabels = local.control_plane_selectors[each.key]
      }
      template = {
        metadata = {
          labels = merge(local.control_namespace_labels, local.control_plane_selectors[each.key])
        }
        spec = {
          automountServiceAccountToken  = each.value.automount_service_account_token
          enableServiceLinks            = false
          serviceAccountName            = each.value.service_account_name
          terminationGracePeriodSeconds = 30
          securityContext = {
            runAsNonRoot = true
            runAsGroup   = 1000
            runAsUser    = 1000
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          containers = [
            merge(
              {
                name            = each.key
                image           = each.value.image
                imagePullPolicy = var.control_plane_image_pull_policy
                ports = [
                  {
                    name          = "http"
                    containerPort = each.value.port
                  },
                ]
                env       = concat(local.control_plane_env[each.key], lookup(local.control_plane_secret_env, each.key, []))
                resources = each.value.resources
                readinessProbe = {
                  httpGet = {
                    path = each.value.readiness_path
                    port = each.value.port
                  }
                  initialDelaySeconds = 5
                  periodSeconds       = 10
                }
                livenessProbe = {
                  httpGet = {
                    path = each.value.liveness_path
                    port = each.value.port
                  }
                  initialDelaySeconds = 15
                  periodSeconds       = 20
                }
                securityContext = {
                  allowPrivilegeEscalation = false
                  capabilities = {
                    drop = ["ALL"]
                  }
                  readOnlyRootFilesystem = true
                }
              },
              length(each.value.command) > 0 ? { command = each.value.command } : {},
              length(each.value.args) > 0 ? { args = each.value.args } : {},
            )
          ]
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.control_service_account,
    kubernetes_manifest.runtime_worker_role_binding,
  ]
}

resource "kubernetes_manifest" "control_service" {
  for_each = local.control_plane_services

  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = each.key
      namespace = var.control_namespace
      labels    = merge(local.control_namespace_labels, local.control_plane_selectors[each.key])
    }
    spec = {
      type     = "ClusterIP"
      selector = local.control_plane_selectors[each.key]
      ports = [
        {
          name       = "http"
          port       = each.value.port
          targetPort = each.value.port
          protocol   = "TCP"
        },
      ]
    }
  }

  depends_on = [kubernetes_manifest.control_deployment]
}

resource "kubernetes_manifest" "target_group_binding" {
  for_each = local.target_group_bindings

  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = each.key
      namespace = var.control_namespace
      labels = merge(local.control_namespace_labels, {
        "app.kubernetes.io/name"      = var.app_name
        "app.kubernetes.io/component" = "target-group-binding"
      }, each.value.labels)
      annotations = each.value.annotations
    }
    spec = {
      targetGroupARN = each.value.target_group_arn
      targetType     = each.value.target_type
      serviceRef = {
        name = each.value.service_name
        port = each.value.service_port
      }
    }
  }

  depends_on = [kubernetes_manifest.control_service]
}

resource "kubernetes_manifest" "worker_service_account" {
  manifest = {
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = var.service_account_name
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "rbi-worker"
      })
    }
    automountServiceAccountToken = false
  }

  depends_on = [kubernetes_manifest.worker_namespace]
}

resource "kubernetes_manifest" "secret_provider_class" {
  for_each = local.secret_provider_classes

  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = each.key
      namespace = each.value.namespace
      labels = merge(
        each.value.namespace == var.control_namespace ? local.control_namespace_labels : local.base_labels,
        {
          "app.kubernetes.io/name"      = var.app_name
          "app.kubernetes.io/component" = "secret-provider-class"
        },
        each.value.labels,
      )
      annotations = each.value.annotations
    }
    spec = merge(
      {
        provider   = each.value.provider
        parameters = each.value.parameters
      },
      length(each.value.secret_objects) > 0 ? {
        secretObjects = [
          for secret_object in each.value.secret_objects : {
            secretName  = secret_object.secret_name
            type        = secret_object.type
            labels      = secret_object.labels
            annotations = secret_object.annotations
            data = [
              for data_item in secret_object.data : {
                objectName = data_item.object_name
                key        = data_item.key
              }
            ]
          }
        ]
      } : {},
    )
  }

  depends_on = [
    kubernetes_manifest.control_namespace,
    kubernetes_manifest.worker_namespace,
  ]
}

resource "kubernetes_manifest" "worker_shared_config" {
  manifest = {
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "rbi-worker-shared-config"
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "rbi-worker-config"
      })
    }
    data = local.shared_config
  }

  depends_on = [kubernetes_manifest.worker_namespace]
}

resource "kubernetes_manifest" "worker_network_policy" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "cloudsec-rbi-worker-egress"
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "rbi-worker"
      })
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress = [
        {
          from = [
            {
              namespaceSelector = {
                matchLabels = {
                  "cloudsec.cisco.com/rbi-plane" = "control"
                }
              }
            },
          ]
        },
      ]
      egress = concat([
        {
          to = [
            {
              namespaceSelector = {
                matchLabels = {
                  "kubernetes.io/metadata.name" = "kube-system"
                }
              }
              podSelector = {
                matchLabels = {
                  "k8s-app" = "kube-dns"
                }
              }
            },
          ]
          ports = [
            {
              protocol = "UDP"
              port     = 53
            },
            {
              protocol = "TCP"
              port     = 53
            },
          ]
        },
        {
          to = [
            {
              namespaceSelector = {
                matchLabels = {
                  "cloudsec.cisco.com/rbi-plane" = "control"
                }
              }
              podSelector = {
                matchLabels = {
                  "app.kubernetes.io/name" = var.app_name
                }
              }
            },
          ]
          ports = [
            {
              protocol = "TCP"
              port     = 443
            },
            {
              protocol = "TCP"
              port     = 8080
            },
            {
              protocol = "TCP"
              port     = 18081
            },
          ]
        },
        {
          to = [
            {
              namespaceSelector = {
                matchLabels = {
                  "cloudsec.cisco.com/rbi-plane" = "control"
                }
              }
              podSelector = {
                matchLabels = {
                  "app.kubernetes.io/component" = "media-gateway"
                }
              }
            },
          ]
          ports = [
            {
              protocol = "TCP"
              port     = 443
            },
            {
              protocol = "TCP"
              port     = 8443
            },
            {
              protocol = "TCP"
              port     = 18082
            },
          ]
        },
        {
          to = [
            {
              namespaceSelector = {
                matchLabels = {
                  "cloudsec.cisco.com/rbi-plane" = "media"
                }
              }
              podSelector = {
                matchLabels = {
                  "app.kubernetes.io/component" = "media-gateway"
                }
              }
            },
          ]
          ports = [
            {
              protocol = "TCP"
              port     = 443
            },
            {
              protocol = "TCP"
              port     = 8443
            },
            {
              protocol = "TCP"
              port     = 18082
            },
          ]
        },
        {
          to = [
            {
              namespaceSelector = {
                matchLabels = {
                  "cloudsec.cisco.com/rbi-plane" = "media"
                }
              }
              podSelector = {
                matchLabels = {
                  "app.kubernetes.io/component" = "turn"
                }
              }
            },
          ]
          ports = [
            {
              protocol = "UDP"
              port     = 3478
            },
            {
              protocol = "TCP"
              port     = 3478
            },
            {
              protocol = "TCP"
              port     = 443
            },
            {
              protocol = "TCP"
              port     = 5349
            },
          ]
        },
        {
          to = [
            {
              namespaceSelector = {
                matchLabels = {
                  "cloudsec.cisco.com/egress-plane" = "swg"
                }
              }
              podSelector = {
                matchLabels = {
                  "app.kubernetes.io/component" = "swg-proxy"
                }
              }
            },
          ]
          ports = [
            {
              protocol = "TCP"
              port     = 80
            },
            {
              protocol = "TCP"
              port     = 443
            },
            {
              protocol = "TCP"
              port     = 3128
            },
          ]
        },
        ],
        var.enable_public_egress ? [
          {
            to = [
              {
                ipBlock = {
                  cidr   = var.public_egress_cidr
                  except = var.public_egress_except_cidrs
                }
              },
            ]
          },
        ] : [],
      )
    }
  }

  depends_on = [
    kubernetes_manifest.control_namespace,
    kubernetes_manifest.worker_namespace,
  ]
}

resource "kubernetes_manifest" "worker_pool_deployment" {
  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = var.pool_deployment_name
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "rbi-worker-pool"
      })
    }
    spec = {
      replicas = var.pool_replicas
      selector = {
        matchLabels = local.pool_selector_labels
      }
      template = {
        metadata = {
          labels = merge(local.pool_selector_labels, local.base_labels, {
            "cloudsec.cisco.com/worker-mode" = "pool"
          })
          annotations = {
            "cloudsec.cisco.com/worker-shared-config-sha256" = sha256(jsonencode(local.shared_config))
          }
        }
        spec = {
          automountServiceAccountToken  = false
          enableServiceLinks            = false
          runtimeClassName              = var.runtime_class_name
          serviceAccountName            = var.service_account_name
          terminationGracePeriodSeconds = 30
          nodeSelector                  = var.worker_node_selector
          tolerations                   = var.worker_tolerations
          securityContext               = local.worker_security_context
          containers = [
            {
              name            = "worker"
              image           = var.worker_image
              imagePullPolicy = var.worker_image_pull_policy
              envFrom = [
                {
                  configMapRef = {
                    name = "rbi-worker-shared-config"
                  }
                },
              ]
              env = [
                {
                  name  = "WORKER_MODE"
                  value = "pool"
                },
                {
                  name = "POOL_WORKER_ID"
                  valueFrom = {
                    fieldRef = {
                      fieldPath = "metadata.name"
                    }
                  }
                },
                {
                  name = "POOL_SHARED_SECRET"
                  valueFrom = {
                    secretKeyRef = {
                      name = var.pool_secret_name
                      key  = var.pool_shared_secret_key
                    }
                  }
                },
              ]
              resources       = var.worker_resources
              securityContext = local.container_security_context
              volumeMounts    = local.volume_mounts
            },
          ]
          volumes = local.volumes
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.worker_service_account,
    kubernetes_manifest.worker_shared_config,
    kubernetes_manifest.worker_network_policy,
  ]
}

resource "kubernetes_manifest" "worker_pool_hpa" {
  count = var.worker_pool_hpa_enabled ? 1 : 0

  manifest = {
    apiVersion = "autoscaling/v2"
    kind       = "HorizontalPodAutoscaler"
    metadata = {
      name      = var.pool_deployment_name
      namespace = var.worker_namespace
      labels = merge(local.base_labels, {
        "app.kubernetes.io/component" = "rbi-worker-pool-autoscaler"
      })
    }
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = var.pool_deployment_name
      }
      minReplicas = var.worker_pool_hpa_min_replicas
      maxReplicas = max(var.worker_pool_hpa_min_replicas, var.worker_pool_hpa_max_replicas)
      metrics = [
        {
          type = "Resource"
          resource = {
            name = "cpu"
            target = {
              type               = "Utilization"
              averageUtilization = var.worker_pool_hpa_cpu_target_utilization
            }
          }
        },
        {
          type = "Resource"
          resource = {
            name = "memory"
            target = {
              type               = "Utilization"
              averageUtilization = var.worker_pool_hpa_memory_target_utilization
            }
          }
        },
      ]
      behavior = {
        scaleUp = {
          stabilizationWindowSeconds = 0
          policies = [
            {
              type          = "Pods"
              value         = 4
              periodSeconds = 60
            },
            {
              type          = "Percent"
              value         = 100
              periodSeconds = 60
            },
          ]
          selectPolicy = "Max"
        }
        scaleDown = {
          stabilizationWindowSeconds = 300
          policies = [
            {
              type          = "Pods"
              value         = 2
              periodSeconds = 60
            },
            {
              type          = "Percent"
              value         = 50
              periodSeconds = 60
            },
          ]
          selectPolicy = "Min"
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.worker_pool_deployment]
}

resource "terraform_data" "session_worker_job_template_revision" {
  input = sha256(jsonencode({
    image                      = var.worker_image
    image_pull_policy          = var.worker_image_pull_policy
    config_map                 = "rbi-worker-shared-config"
    shared_config_sha256       = sha256(jsonencode(local.shared_config))
    resources                  = var.worker_resources
    runtime_class_name         = var.runtime_class_name
    service_account_name       = var.service_account_name
    node_selector              = var.worker_node_selector
    tolerations                = var.worker_tolerations
    active_deadline_seconds    = var.session_job_active_deadline_seconds
    ttl_seconds_after_finished = var.session_job_ttl_seconds_after_finished
    session_secret_name        = var.session_secret_name
    session_id_placeholder     = var.session_id_placeholder
    target_url_placeholder     = var.target_url_placeholder
  }))
}

resource "kubernetes_manifest" "session_worker_job" {
  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  lifecycle {
    replace_triggered_by = [
      terraform_data.session_worker_job_template_revision,
    ]
  }

  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = var.session_job_name
      namespace = var.worker_namespace
      labels    = local.session_labels
    }
    spec = {
      suspend                 = var.session_job_suspend
      backoffLimit            = 0
      completions             = 1
      parallelism             = 1
      activeDeadlineSeconds   = var.session_job_active_deadline_seconds
      ttlSecondsAfterFinished = var.session_job_ttl_seconds_after_finished
      template = {
        metadata = {
          labels = merge(local.session_labels, {
            "cloudsec.cisco.com/worker-mode" = "session"
          })
          annotations = {
            "cloudsec.cisco.com/worker-shared-config-sha256" = sha256(jsonencode(local.shared_config))
          }
        }
        spec = {
          automountServiceAccountToken  = false
          enableServiceLinks            = false
          restartPolicy                 = "Never"
          runtimeClassName              = var.runtime_class_name
          serviceAccountName            = var.service_account_name
          terminationGracePeriodSeconds = 30
          nodeSelector                  = var.worker_node_selector
          tolerations                   = var.worker_tolerations
          securityContext               = local.worker_security_context
          containers = [
            {
              name            = "worker"
              image           = var.worker_image
              imagePullPolicy = var.worker_image_pull_policy
              envFrom = [
                {
                  configMapRef = {
                    name = "rbi-worker-shared-config"
                  }
                },
              ]
              env = [
                {
                  name  = "WORKER_MODE"
                  value = "session"
                },
                {
                  name  = "SESSION_ID"
                  value = var.session_id_placeholder
                },
                {
                  name  = "TARGET_URL"
                  value = var.target_url_placeholder
                },
                {
                  name = "WORKER_TOKEN"
                  valueFrom = {
                    secretKeyRef = {
                      name = var.session_secret_name
                      key  = "worker-token"
                    }
                  }
                },
                {
                  name = "TURN_USERNAME"
                  valueFrom = {
                    secretKeyRef = {
                      name = var.session_secret_name
                      key  = "turn-username"
                    }
                  }
                },
                {
                  name = "TURN_PASSWORD"
                  valueFrom = {
                    secretKeyRef = {
                      name = var.session_secret_name
                      key  = "turn-password"
                    }
                  }
                },
              ]
              resources       = var.worker_resources
              securityContext = local.container_security_context
              volumeMounts    = local.volume_mounts
            },
          ]
          volumes = local.volumes
        }
      }
    }
  }

  computed_fields = [
    "spec.selector",
    "spec.template.metadata.labels",
  ]

  depends_on = [
    kubernetes_manifest.worker_service_account,
    kubernetes_manifest.worker_shared_config,
    kubernetes_manifest.worker_network_policy,
  ]
}
