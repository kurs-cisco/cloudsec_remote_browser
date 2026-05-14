locals {
  root_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "standalone-rbi-apps"
    },
    var.tags,
  )

  kubernetes_labels = {
    "app.kubernetes.io/managed-by"   = "terraform"
    "cloudsec.cisco.com/environment" = var.environment
  }

  public_endpoint_hostname = var.public_endpoint_hostname != "" ? var.public_endpoint_hostname : "${var.project_name}.${var.aws_region}.invalid"
  turn_hostname            = var.turn_hostname != "" ? var.turn_hostname : "turn.${local.public_endpoint_hostname}"
  worker_turn_hostname     = var.worker_turn_hostname != "" ? var.worker_turn_hostname : local.turn_hostname
  public_base_url          = "https://${local.public_endpoint_hostname}"

  control_plane_services = {
    runtime = {
      image                           = var.runtime_image
      port                            = 8080
      replicas                        = var.control_plane_replicas
      service_account_name            = "rbi-runtime"
      automount_service_account_token = true
      readiness_path                  = "/api/health"
      liveness_path                   = "/api/health"
      env = merge({
        NODE_ENV                                  = var.require_redis_backends ? "production" : "development"
        PUBLIC_BASE_URL                           = local.public_base_url
        PUBLIC_WS_URL                             = "wss://${local.public_endpoint_hostname}/ws"
        WORKER_WS_URL                             = "ws://runtime.${var.control_namespace}.svc.cluster.local:8080/ws/worker"
        POOL_WS_URL                               = "ws://runtime.${var.control_namespace}.svc.cluster.local:8080/ws/pool"
        SERVICE_HOSTNAME                          = local.public_endpoint_hostname
        TURN_HOSTNAME                             = local.turn_hostname
        WORKER_TURN_HOST                          = local.worker_turn_hostname
        PUBLIC_TURN_TLS_PORT                      = tostring(var.public_turn_tls_port)
        VIEWER_ICE_TRANSPORT_POLICY               = "relay"
        ALLOWED_ICE_CANDIDATE_TYPES               = "relay"
        SWG_BOOTSTRAP_LOCAL_ONLY                  = "false"
        SWG_BOOTSTRAP_ALLOWED_CONTRACT_VERSIONS   = "v2"
        SWG_BOOTSTRAP_ALLOWED_REQUEST_KINDS       = "http-document,https-decrypted-document"
        SWG_BOOTSTRAP_ALLOWED_ORIGINAL_METHODS    = "GET,HEAD"
        SWG_BOOTSTRAP_ALLOWED_PROVIDERS           = "in_house"
        SWG_BOOTSTRAP_ALLOWED_PROVIDER_CATEGORIES = "cat-b"
        RBI_FALLBACK_PROVIDER                     = "menlo"
        SESSION_AUTHORITY_BOOTSTRAP_URL           = "http://session-authority.${var.control_namespace}.svc.cluster.local:18081/v1/bootstrap"
        WORKER_IMAGE                              = var.worker_image
        WORKER_IMAGE_DIGEST                       = var.worker_image
        WORKER_LAUNCH_MODE                        = "kubernetes"
        KUBERNETES_WORKER_NAMESPACE               = var.worker_namespace
        KUBERNETES_WORKER_RUNTIME_CLASS_NAME      = var.runtime_class_name
        KUBERNETES_WORKER_CONFIG_MAP_NAME         = "rbi-worker-shared-config"
        KUBERNETES_WORKER_SERVICE_ACCOUNT         = "rbi-worker"
        IDLE_REAPER_INTERVAL_MS                   = "30000"
        KUBERNETES_ORPHAN_REAPER_ENABLED          = "true"
        KUBERNETES_ORPHAN_REAPER_INTERVAL_MS      = "30000"
        KUBERNETES_ORPHAN_WORKER_GRACE_MS         = "60000"
        WARM_POOL_ENABLED                         = "true"
        WARM_POOL_ALLOCATION_WAIT_MS              = "1500"
        DISPLAY_WIDTH                             = "1920"
        DISPLAY_HEIGHT                            = "1080"
        CAPTURE_FRAMERATE                         = "20"
        VIDEO_CODEC_PREFERENCES                   = "VP8"
        VIDEO_MIN_BITRATE_BPS                     = "600000"
        VIDEO_START_BITRATE_BPS                   = "1500000"
        VIDEO_MAX_BITRATE_BPS                     = "3000000"
        }, var.redis_url != "" ? {
        REDIS_URL                 = var.redis_url
        REDIS_TLS                 = "true"
        REDIS_KEY_PREFIX          = var.redis_key_prefix
        SESSION_STORE_BACKEND     = "redis"
        SIGNAL_BUS_BACKEND        = "redis"
        WORKER_POOL_STORE_BACKEND = "redis"
        WORKER_POOL_BUS_BACKEND   = "redis"
        REQUIRE_REDIS_BACKENDS    = var.require_redis_backends ? "true" : "false"
        RBI_REDIS_ONLY            = var.require_redis_backends ? "true" : "false"
        RBI_PRODUCTION_PROOF      = var.require_redis_backends ? "true" : "false"
      } : {})
    }
    session-authority = {
      image    = var.session_authority_image
      port     = 18081
      replicas = var.control_plane_replicas
      env = {
        SESSION_AUTHORITY_ADDR                    = ":18081"
        SESSION_AUTHORITY_DEFAULT_REGION          = var.aws_region
        SESSION_AUTHORITY_REGIONS                 = var.aws_region
        SESSION_AUTHORITY_GATEWAYS_PER_REGION     = "1"
        SESSION_AUTHORITY_HANDOFF_BASE_URL        = local.public_base_url
        SESSION_AUTHORITY_GATEWAY_PUBLIC_BASE_URL = local.public_base_url
        SESSION_AUTHORITY_GATEWAY_PUBLIC_WS_URL   = "wss://${local.public_endpoint_hostname}/ws"
        SESSION_AUTHORITY_RELAY_MODE              = "gateway-media-relay"
        SESSION_AUTHORITY_RUNTIME_BASE_URL        = "http://runtime.${var.control_namespace}.svc.cluster.local:8080"
        SESSION_AUTHORITY_MEDIA_GATEWAY_BASE_URL  = "http://media-gateway.${var.control_namespace}.svc.cluster.local:18082"
      }
    }
    media-gateway = {
      image    = var.media_gateway_image
      port     = 18082
      replicas = coalesce(var.media_gateway_replicas, var.control_plane_replicas)
      env = merge(
        {
          MEDIA_GATEWAY_ADDR                           = ":18082"
          MEDIA_GATEWAY_REGION                         = var.aws_region
          MEDIA_GATEWAY_ID                             = "gateway-${var.aws_region}-01"
          MEDIA_GATEWAY_PUBLIC_BASE_URL                = local.public_base_url
          MEDIA_GATEWAY_PUBLIC_WS_URL                  = "wss://${local.public_endpoint_hostname}/ws"
          MEDIA_GATEWAY_WORKER_BASE_URL                = "http://media-gateway.${var.control_namespace}.svc.cluster.local:18082"
          MEDIA_GATEWAY_WORKER_WS_URL                  = "ws://media-gateway.${var.control_namespace}.svc.cluster.local:18082"
          MEDIA_GATEWAY_ICE_URLS                       = "stun:${local.worker_turn_hostname}:3478,turn:${local.worker_turn_hostname}:3478?transport=udp,turn:${local.worker_turn_hostname}:3478?transport=tcp"
          MEDIA_GATEWAY_ENABLE_MEDIA_RELAY             = "true"
          MEDIA_GATEWAY_DEFAULT_RELAY_MODE             = "gateway-media-relay"
          MEDIA_GATEWAY_PREFERRED_TRANSPORT            = "webrtc"
          MEDIA_GATEWAY_SUPPORTED_TRANSPORTS           = "webrtc,websocket"
          MEDIA_GATEWAY_RUNTIME_NOTIFY_BASE_URL        = "http://runtime.${var.control_namespace}.svc.cluster.local:8080"
          MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS            = tostring(var.media_gateway_max_active_sessions)
          MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_TENANT = tostring(var.media_gateway_max_active_sessions_per_tenant)
          MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_WORKER = tostring(var.media_gateway_max_active_sessions_per_worker)
        },
        var.redis_url != "" ? {
          MEDIA_GATEWAY_STATE_BACKEND             = "redis"
          MEDIA_GATEWAY_REDIS_URL                 = var.redis_url
          MEDIA_GATEWAY_REDIS_TLS                 = "true"
          MEDIA_GATEWAY_REDIS_KEY_PREFIX          = var.redis_key_prefix
          MEDIA_GATEWAY_SESSION_STORE_TTL_SECONDS = "10800"
        } : {}
      )
    }
    file-broker = {
      image    = var.file_broker_image
      port     = 8093
      replicas = var.control_plane_replicas
      env = {
        FILE_BROKER_ADDR = ":8093"
      }
    }
    clipboard-broker = {
      image    = var.clipboard_broker_image
      port     = 8094
      replicas = var.control_plane_replicas
      env = {
        CLIPBOARD_BROKER_ADDR = ":8094"
      }
    }
  }

  managed_target_group_bindings = merge(
    try(var.control_plane_target_group_arns["control-plane"], "") != "" ? {
      control-plane = {
        target_group_arn = var.control_plane_target_group_arns["control-plane"]
        service_name     = "runtime"
        service_port     = 8080
        target_type      = "ip"
        labels = {
          "cloudsec.cisco.com/rbi-attachment" = "public-control-plane"
        }
        annotations = {}
      }
    } : {},
    try(var.control_plane_target_group_arns["media-gateway"], "") != "" ? {
      media-gateway = {
        target_group_arn = var.control_plane_target_group_arns["media-gateway"]
        service_name     = "media-gateway"
        service_port     = 18082
        target_type      = "ip"
        labels = {
          "cloudsec.cisco.com/rbi-attachment" = "public-media-gateway"
        }
        annotations = {}
      }
    } : {},
    var.bootstrap_target_group_arn != "" ? {
      bootstrap-runtime = {
        target_group_arn = var.bootstrap_target_group_arn
        service_name     = "runtime"
        service_port     = 8080
        target_type      = "ip"
        labels = {
          "cloudsec.cisco.com/rbi-attachment" = "privatelink-bootstrap"
        }
        annotations = {}
      }
    } : {},
  )

  service_target_ports = toset(["8080", "18082"])
}

resource "aws_security_group_rule" "cluster_service_ingress" {
  for_each = length(var.service_target_ingress_cidrs) > 0 ? local.service_target_ports : toset([])

  type              = "ingress"
  security_group_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "RBI ALB/NLB health checks and service traffic to pod target port ${each.value}"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  protocol          = "tcp"
  cidr_blocks       = var.service_target_ingress_cidrs
}

module "k8s_addons" {
  source = "../../../../modules/k8s-addons"

  runtime_class_name    = var.runtime_class_name
  runtime_handler       = "kata-clh"
  enable_metrics_server = var.enable_metrics_server
  metrics_server_image  = var.metrics_server_image
  labels                = local.kubernetes_labels
}

module "rbi_apps" {
  source = "../../../../modules/rbi-apps"

  app_name                 = "cloudsec-remote-browser"
  create_control_namespace = var.create_control_namespace
  control_namespace        = var.control_namespace
  worker_namespace         = var.worker_namespace
  runtime_class_name       = module.k8s_addons.runtime_class_name
  control_plane_services   = local.control_plane_services
  control_plane_secret_env = {
    runtime = {
      TOKEN_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "TOKEN_SECRET"
      }
      TURN_SHARED_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "TURN_SHARED_SECRET"
      }
      SWG_SHARED_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "SWG_SHARED_SECRET"
      }
      RBI_INTERNAL_SHARED_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "RBI_INTERNAL_SHARED_SECRET"
      }
      POOL_WORKER_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "POOL_WORKER_SECRET"
      }
    }
    session-authority = {
      RBI_INTERNAL_SHARED_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "RBI_INTERNAL_SHARED_SECRET"
      }
    }
    media-gateway = {
      RBI_INTERNAL_SHARED_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "RBI_INTERNAL_SHARED_SECRET"
      }
      MEDIA_GATEWAY_TURN_SHARED_SECRET = {
        secret_name = var.runtime_secret_name
        key         = "TURN_SHARED_SECRET"
      }
    }
  }
  worker_image = var.worker_image
  shared_config = merge(
    {
      WORKER_REGION              = var.aws_region
      WORKER_RUNTIME_CLASS       = var.runtime_class_name
      WORKER_MEDIA_MODE          = "gateway-webrtc-relay"
      WORKER_IMAGE_DIGEST        = var.worker_image
      POOL_RECYCLE_AFTER_SESSION = "1"
    },
    var.worker_shared_config,
  )
  pool_replicas                             = var.pool_replicas
  worker_pool_hpa_enabled                   = var.worker_pool_hpa_enabled
  worker_pool_hpa_min_replicas              = var.worker_pool_hpa_min_replicas
  worker_pool_hpa_max_replicas              = var.worker_pool_hpa_max_replicas
  worker_pool_hpa_cpu_target_utilization    = var.worker_pool_hpa_cpu_target_utilization
  worker_pool_hpa_memory_target_utilization = var.worker_pool_hpa_memory_target_utilization
  target_group_bindings                     = merge(local.managed_target_group_bindings, var.target_group_bindings)
  secret_provider_classes                   = var.secret_provider_classes
  labels                                    = local.kubernetes_labels

  depends_on = [module.k8s_addons]
}
