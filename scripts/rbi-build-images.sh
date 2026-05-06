#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLOUDSEC_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
WORKSPACE_DIR="$(cd -- "${CLOUDSEC_DIR}/.." && pwd -P)"
IMAGES_DIR="${CLOUDSEC_DIR}/infra/terraform/aws-standalone-rbi/images"
DEFAULT_CONFIG="infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env"

CONFIG_PATH="${RBI_CONFIG_PATH:-${DEFAULT_CONFIG}}"
COMPONENT="all"
MODE="build"
ARTIFACT_DIR="${IMAGES_DIR}/artifacts"
ARTIFACT_ENV=""
IMAGE_TAG="${RBI_IMAGE_TAG:-}"
IMAGE_TAG_EXPLICIT=0
CONTAINER_TOOL="${RBI_CONTAINER_TOOL:-docker}"
PLATFORM="${RBI_IMAGE_PLATFORM:-linux/amd64}"
ECR_LOGIN=1
BUILD_ARGS=()

if [[ -n "${IMAGE_TAG}" ]]; then
  IMAGE_TAG_EXPLICIT=1
fi

log() {
  printf '[rbi-build-images] %s\n' "$*"
}

fatal() {
  printf '[rbi-build-images] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: rbi-build-images.sh [config.env] [options]

Build, push, and/or promote standalone RBI container image digests.

Options:
  --config PATH             Shell env file to source.
  --component NAME          all, control-plane, session-authority, media-gateway,
                            file-broker, clipboard-broker, or worker.
  --mode MODE               build, promote, or build-promote. Default: build.
  --build                   Alias for --mode build.
  --promote                 Alias for --mode promote.
  --build-promote           Build, push, resolve digests, and promote.
  --push                    Push images after build without promoting.
  --artifact-dir DIR        Directory for generated Dockerfiles and artifact env.
  --artifact-env FILE       Env file containing/promoted image digests.
  --tag TAG                 Tag to apply when config image refs are untagged or digest-pinned.
  --platform PLATFORM       Docker platform. Default: linux/amd64.
  --container-tool CMD      docker or podman. Default: docker.
  --build-arg KEY=VALUE     Extra container build arg. May be repeated.
  --no-ecr-login            Skip ECR docker login before push.
  -h, --help                Show this help.

Promotion defaults match manage-rbi-env.sh under:
  /cloudsec-rbi/<env>/<region>/images/*-image-digest
EOF
}

abs_path() {
  local path="$1"
  local dir base
  dir="$(cd -- "$(dirname -- "${path}")" && pwd -P)"
  base="$(basename -- "${path}")"
  printf '%s/%s\n' "${dir}" "${base}"
}

resolve_path() {
  local input="$1"
  local candidate
  for candidate in \
    "${input}" \
    "${CLOUDSEC_DIR}/${input}" \
    "${WORKSPACE_DIR}/${input}"
  do
    if [[ -f "${candidate}" ]]; then
      abs_path "${candidate}"
      return
    fi
  done
  fatal "file not found: ${input}"
}

shell_string() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "${value}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || fatal "--config requires a path"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --component)
        [[ $# -ge 2 ]] || fatal "--component requires a value"
        COMPONENT="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || fatal "--mode requires a value"
        MODE="$2"
        shift 2
        ;;
      --build)
        MODE="build"
        shift
        ;;
      --promote)
        MODE="promote"
        shift
        ;;
      --build-promote)
        MODE="build-promote"
        shift
        ;;
      --push)
        MODE="push"
        shift
        ;;
      --artifact-dir)
        [[ $# -ge 2 ]] || fatal "--artifact-dir requires a directory"
        ARTIFACT_DIR="$2"
        shift 2
        ;;
      --artifact-env)
        [[ $# -ge 2 ]] || fatal "--artifact-env requires a file"
        ARTIFACT_ENV="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || fatal "--tag requires a value"
        IMAGE_TAG="$2"
        IMAGE_TAG_EXPLICIT=1
        shift 2
        ;;
      --platform)
        [[ $# -ge 2 ]] || fatal "--platform requires a value"
        PLATFORM="$2"
        shift 2
        ;;
      --container-tool)
        [[ $# -ge 2 ]] || fatal "--container-tool requires a command"
        CONTAINER_TOOL="$2"
        shift 2
        ;;
      --build-arg)
        [[ $# -ge 2 ]] || fatal "--build-arg requires KEY=VALUE"
        BUILD_ARGS+=("--build-arg" "$2")
        shift 2
        ;;
      --no-ecr-login)
        ECR_LOGIN=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        fatal "unknown option: $1"
        ;;
      *)
        CONFIG_PATH="$1"
        shift
        ;;
    esac
  done
}

validate_selection() {
  case "${COMPONENT}" in
    all|control-plane|session-authority|media-gateway|file-broker|clipboard-broker|worker) ;;
    *) fatal "unsupported component: ${COMPONENT}" ;;
  esac

  case "${MODE}" in
    build|push|promote|build-promote) ;;
    *) fatal "--mode must be build, push, promote, or build-promote" ;;
  esac
}

component_requested() {
  [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "$1" ]]
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fatal "missing required command: ${cmd}"
  done
}

load_config() {
  local resolved
  resolved="$(resolve_path "${CONFIG_PATH}")"
  log "sourcing config ${resolved}"
  set -a
  # shellcheck source=/dev/null
  source "${resolved}"
  set +a
}

init_context() {
  AWS_REGION="${AWS_REGION:-${RBI_REGION:-${AWS_DEFAULT_REGION:-}}}"
  [[ -n "${AWS_REGION}" ]] || fatal "AWS_REGION or RBI_REGION is required"
  AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
  export AWS_REGION AWS_DEFAULT_REGION

  RBI_ENV="${TF_VAR_environment:-${RBI_ENVIRONMENT:-dev}}"
  RBI_PROJECT="${TF_VAR_project_name:-${RBI_PROJECT_NAME:-cloudsec-rbi}}"
  IMAGE_TAG="${IMAGE_TAG:-${RBI_ENV}-$(date -u '+%Y%m%d%H%M%S')}"
  IMAGE_SSM_PREFIX="${RBI_IMAGE_SSM_PREFIX:-/cloudsec-rbi/${RBI_ENV}/${AWS_REGION}/images}"

  mkdir -p "${ARTIFACT_DIR}"
  if [[ -z "${ARTIFACT_ENV}" ]]; then
    ARTIFACT_ENV="${ARTIFACT_DIR}/rbi-image-artifacts.env"
  fi
}

service_env_var() {
  case "$1" in
    control-plane) printf 'TF_VAR_runtime_image' ;;
    session-authority) printf 'TF_VAR_session_authority_image' ;;
    media-gateway) printf 'TF_VAR_media_gateway_image' ;;
    file-broker) printf 'TF_VAR_file_broker_image' ;;
    clipboard-broker) printf 'TF_VAR_clipboard_broker_image' ;;
    worker) printf 'TF_VAR_worker_image' ;;
  esac
}

service_digest_var() {
  case "$1" in
    control-plane) printf 'RBI_CONTROL_PLANE_IMAGE_DIGEST' ;;
    session-authority) printf 'RBI_SESSION_AUTHORITY_IMAGE_DIGEST' ;;
    media-gateway) printf 'RBI_MEDIA_GATEWAY_IMAGE_DIGEST' ;;
    file-broker) printf 'RBI_FILE_BROKER_IMAGE_DIGEST' ;;
    clipboard-broker) printf 'RBI_CLIPBOARD_BROKER_IMAGE_DIGEST' ;;
    worker) printf 'RBI_WORKER_IMAGE_DIGEST' ;;
  esac
}

service_ssm_var() {
  case "$1" in
    control-plane) printf 'RBI_CONTROL_PLANE_IMAGE_DIGEST_SSM_PARAMETER' ;;
    session-authority) printf 'RBI_SESSION_AUTHORITY_IMAGE_DIGEST_SSM_PARAMETER' ;;
    media-gateway) printf 'RBI_MEDIA_GATEWAY_IMAGE_DIGEST_SSM_PARAMETER' ;;
    file-broker) printf 'RBI_FILE_BROKER_IMAGE_DIGEST_SSM_PARAMETER' ;;
    clipboard-broker) printf 'RBI_CLIPBOARD_BROKER_IMAGE_DIGEST_SSM_PARAMETER' ;;
    worker) printf 'RBI_WORKER_IMAGE_DIGEST_SSM_PARAMETER' ;;
  esac
}

service_ssm_suffix() {
  case "$1" in
    control-plane) printf 'control-plane-image-digest' ;;
    session-authority) printf 'session-authority-image-digest' ;;
    media-gateway) printf 'media-gateway-image-digest' ;;
    file-broker) printf 'file-broker-image-digest' ;;
    clipboard-broker) printf 'clipboard-broker-image-digest' ;;
    worker) printf 'worker-image-digest' ;;
  esac
}

service_cmd_path() {
  case "$1" in
    session-authority) printf './cmd/session-authority' ;;
    media-gateway) printf './cmd/media-gateway' ;;
    file-broker) printf './cmd/file-broker' ;;
    clipboard-broker) printf './cmd/clipboard-broker' ;;
    *) return 1 ;;
  esac
}

target_image_ref() {
  local service="$1"
  local var_name ref
  var_name="$(service_env_var "${service}")"
  ref="${!var_name:-}"
  [[ -n "${ref}" ]] || fatal "${var_name} is required for ${service}"

  if [[ "${IMAGE_TAG_EXPLICIT}" -eq 1 ]]; then
    ref="${ref%@sha256:*}"
    if [[ "${ref##*/}" == *:* ]]; then
      ref="${ref%:*}"
    fi
    printf '%s:%s\n' "${ref}" "${IMAGE_TAG}"
    return
  fi

  if [[ "${ref}" == *@sha256:* ]]; then
    printf '%s:%s\n' "${ref%@sha256:*}" "${IMAGE_TAG}"
    return
  fi

  if [[ "${ref##*/}" == *:* ]]; then
    printf '%s\n' "${ref}"
    return
  fi

  printf '%s:%s\n' "${ref}" "${IMAGE_TAG}"
}

write_go_dockerfile() {
  local service="$1"
  local dockerfile="${ARTIFACT_DIR}/Dockerfile.${service}"
  local cmd_path
  cmd_path="$(service_cmd_path "${service}")"

  cat >"${dockerfile}" <<EOF
ARG GO_VERSION=1.24
FROM golang:\${GO_VERSION}-bookworm AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
ARG SERVICE_CMD=${cmd_path}
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/service \${SERVICE_CMD}

FROM debian:bookworm-slim
RUN apt-get update \\
    && apt-get install -y --no-install-recommends ca-certificates \\
    && rm -rf /var/lib/apt/lists/*
RUN groupadd --system rbi \\
    && useradd --system --gid rbi --no-create-home --shell /usr/sbin/nologin rbi
USER rbi:rbi
COPY --from=build /out/service /usr/local/bin/cloudsec-rbi-service
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/cloudsec-rbi-service"]
EOF

  printf '%s\n' "${dockerfile}"
}

build_service() {
  local service="$1"
  local image_ref="$2"
  local context dockerfile
  local platform_args=()

  require_cmd "${CONTAINER_TOOL}"
  [[ -n "${PLATFORM}" ]] && platform_args=("--platform" "${PLATFORM}")

  case "${service}" in
    control-plane)
      context="${CLOUDSEC_DIR}"
      dockerfile="${CLOUDSEC_DIR}/Dockerfile"
      ;;
    worker)
      context="${CLOUDSEC_DIR}/worker"
      dockerfile="${CLOUDSEC_DIR}/worker/Dockerfile"
      ;;
    session-authority|media-gateway|file-broker|clipboard-broker)
      context="${CLOUDSEC_DIR}/services"
      dockerfile="$(write_go_dockerfile "${service}")"
      ;;
    *)
      fatal "unsupported service ${service}"
      ;;
  esac

  log "building ${service} image ${image_ref}"
  "${CONTAINER_TOOL}" build \
    "${platform_args[@]}" \
    "${BUILD_ARGS[@]}" \
    -t "${image_ref}" \
    -f "${dockerfile}" \
    "${context}"
}

registry_from_ref() {
  printf '%s\n' "${1%%/*}"
}

is_ecr_registry() {
  [[ "$1" == *".dkr.ecr."*".amazonaws.com"* ]]
}

repository_from_ref() {
  local ref_no_digest="${1%@sha256:*}"
  local ref_no_tag="${ref_no_digest%:*}"
  printf '%s\n' "${ref_no_tag#*/}"
}

tag_from_ref() {
  local leaf="${1##*/}"
  [[ "${leaf}" == *:* ]] || fatal "image ref is missing a tag: $1"
  printf '%s\n' "${leaf##*:}"
}

ecr_login_if_needed() {
  local registry="$1"
  [[ "${ECR_LOGIN}" -eq 1 ]] || return 0
  is_ecr_registry "${registry}" || return 0
  require_cmd aws
  log "logging in to ECR registry ${registry}"
  aws ecr get-login-password --region "${AWS_REGION}" | "${CONTAINER_TOOL}" login --username AWS --password-stdin "${registry}" >/dev/null
}

resolve_digest_ref() {
  local image_ref="$1"
  local registry repository tag digest

  registry="$(registry_from_ref "${image_ref}")"
  repository="$(repository_from_ref "${image_ref}")"
  tag="$(tag_from_ref "${image_ref}")"

  if is_ecr_registry "${registry}" && command -v aws >/dev/null 2>&1; then
    digest="$(aws ecr describe-images \
      --repository-name "${repository}" \
      --image-ids "imageTag=${tag}" \
      --query 'imageDetails[0].imageDigest' \
      --output text)"
    if [[ "${digest}" == sha256:* ]]; then
      printf '%s/%s@%s\n' "${registry}" "${repository}" "${digest}"
      return
    fi
  fi

  "${CONTAINER_TOOL}" image inspect "${image_ref}" --format '{{index .RepoDigests 0}}'
}

push_service() {
  local service="$1"
  local image_ref="$2"
  local registry digest_ref

  registry="$(registry_from_ref "${image_ref}")"
  ecr_login_if_needed "${registry}"

  log "pushing ${service} image ${image_ref}"
  "${CONTAINER_TOOL}" push "${image_ref}"

  digest_ref="$(resolve_digest_ref "${image_ref}")"
  [[ "${digest_ref}" == *@sha256:* ]] || fatal "could not resolve pushed digest for ${service}"
  set_digest "${service}" "${digest_ref}"
  log "${service} digest ${digest_ref}"
}

set_digest() {
  local service="$1"
  local value="$2"
  local var_name
  var_name="$(service_digest_var "${service}")"
  export "${var_name}=${value}"
}

get_digest() {
  local service="$1"
  local var_name
  var_name="$(service_digest_var "${service}")"
  printf '%s\n' "${!var_name:-}"
}

ssm_parameter_for_service() {
  local service="$1"
  local var_name value
  var_name="$(service_ssm_var "${service}")"
  value="${!var_name:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s/%s\n' "${IMAGE_SSM_PREFIX}" "$(service_ssm_suffix "${service}")"
  fi
}

put_ssm() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" ]] || fatal "empty value for ${name}"
  require_cmd aws
  aws ssm put-parameter \
    --name "${name}" \
    --type String \
    --value "${value}" \
    --overwrite >/dev/null
  log "promoted ${value} to ${name}"
}

services() {
  printf '%s\n' \
    control-plane \
    session-authority \
    media-gateway \
    file-broker \
    clipboard-broker \
    worker
}

load_artifact_env() {
  [[ -f "${ARTIFACT_ENV}" ]] || return 0
  log "loading artifact env ${ARTIFACT_ENV}"
  set -a
  # shellcheck source=/dev/null
  source "${ARTIFACT_ENV}"
  set +a
  IMAGE_SSM_PREFIX="${RBI_IMAGE_SSM_PREFIX:-${IMAGE_SSM_PREFIX}}"
}

write_artifact_env() {
  local service digest ssm
  : >"${ARTIFACT_ENV}"
  printf 'export RBI_IMAGE_SSM_PREFIX=%s\n' "$(shell_string "${IMAGE_SSM_PREFIX}")" >>"${ARTIFACT_ENV}"

  for service in $(services); do
    if component_requested "${service}"; then
      digest="$(get_digest "${service}")"
      ssm="$(ssm_parameter_for_service "${service}")"
      if [[ -n "${digest}" ]]; then
        printf 'export %s=%s\n' "$(service_digest_var "${service}")" "$(shell_string "${digest}")" >>"${ARTIFACT_ENV}"
      fi
      printf 'export %s=%s\n' "$(service_ssm_var "${service}")" "$(shell_string "${ssm}")" >>"${ARTIFACT_ENV}"
    fi
  done

  log "wrote artifact env ${ARTIFACT_ENV}"
}

promote_artifacts() {
  local service digest ssm

  for service in $(services); do
    if component_requested "${service}"; then
      digest="$(get_digest "${service}")"
      [[ "${digest}" == *@sha256:* ]] || fatal "${service} digest is required for promotion"
      ssm="$(ssm_parameter_for_service "${service}")"
      put_ssm "${ssm}" "${digest}"
    fi
  done
}

main() {
  local service image_ref

  parse_args "$@"
  validate_selection
  load_config
  init_context

  if [[ "${MODE}" == "promote" ]]; then
    load_artifact_env
    promote_artifacts
    return
  fi

  for service in $(services); do
    if component_requested "${service}"; then
      image_ref="$(target_image_ref "${service}")"
      build_service "${service}" "${image_ref}"
      if [[ "${MODE}" == "push" || "${MODE}" == "build-promote" ]]; then
        push_service "${service}" "${image_ref}"
      fi
    fi
  done

  write_artifact_env

  if [[ "${MODE}" == "build-promote" ]]; then
    promote_artifacts
  fi
}

main "$@"
