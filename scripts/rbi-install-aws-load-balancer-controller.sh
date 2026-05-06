#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${1:-${DEFAULT_CONFIG}}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

require_cmd aws
require_cmd helm
require_cmd kubectl
require_cmd openssl

AWS_REGION="${AWS_REGION:-${TF_VAR_aws_region:-}}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
ENVIRONMENT="${TF_VAR_environment:-${RBI_ENVIRONMENT:-dev}}"
CLUSTER_NAME="${TF_VAR_cluster_name:-cloudsec-rbi-${AWS_REGION}}"
SERVICE_ACCOUNT_NAMESPACE="${RBI_AWS_LBC_NAMESPACE:-kube-system}"
SERVICE_ACCOUNT_NAME="${RBI_AWS_LBC_SERVICE_ACCOUNT:-aws-load-balancer-controller}"
POLICY_NAME="${RBI_AWS_LBC_POLICY_NAME:-cloudsec-rbi-${ENVIRONMENT}-${AWS_REGION}-aws-load-balancer-controller}"
ROLE_NAME="${RBI_AWS_LBC_ROLE_NAME:-cloudsec-rbi-${ENVIRONMENT}-${AWS_REGION}-aws-load-balancer-controller}"
POLICY_FILE="${RBI_AWS_LBC_POLICY_FILE:-${TF_ROOT}/policies/aws-load-balancer-controller-policy.json}"
CHART_VERSION="${RBI_AWS_LBC_CHART_VERSION:-}"
FORCE_REINSTALL="${RBI_AWS_LBC_FORCE_REINSTALL:-0}"

[[ -n "${AWS_REGION}" ]] || die "AWS_REGION is required"
[[ -n "${AWS_ACCOUNT_ID}" ]] || die "AWS_ACCOUNT_ID is required"
[[ -f "${POLICY_FILE}" ]] || die "policy file not found: ${POLICY_FILE}"

AWS_ARGS=(--region "${AWS_REGION}")
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${AWS_PROFILE}")
fi

log "discover EKS cluster metadata"
CLUSTER_JSON="$(aws eks describe-cluster "${AWS_ARGS[@]}" --name "${CLUSTER_NAME}" --output json)"
VPC_ID="$(printf '%s' "${CLUSTER_JSON}" | sed -n 's/.*"vpcId": *"\([^"]*\)".*/\1/p' | head -n 1)"
OIDC_ISSUER="$(printf '%s' "${CLUSTER_JSON}" | sed -n 's/.*"issuer": *"\([^"]*\)".*/\1/p' | head -n 1)"

[[ -n "${VPC_ID}" ]] || die "could not resolve cluster VPC ID"
[[ -n "${OIDC_ISSUER}" ]] || die "could not resolve cluster OIDC issuer"

OIDC_PROVIDER="${OIDC_ISSUER#https://}"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
OIDC_HOST="${OIDC_PROVIDER%%/*}"

log "ensure IAM OIDC provider"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
  THUMBPRINT="$(
    openssl s_client -servername "${OIDC_HOST}" -showcerts -connect "${OIDC_HOST}:443" </dev/null 2>/dev/null \
      | awk '/BEGIN CERTIFICATE/{cert=""} {cert=cert $0 ORS} /END CERTIFICATE/{last=cert} END{printf "%s", last}' \
      | openssl x509 -fingerprint -noout -sha1 \
      | sed 's/^.*=//' \
      | tr -d ':'
  )"
  [[ -n "${THUMBPRINT}" ]] || die "could not calculate OIDC thumbprint for ${OIDC_HOST}"
  aws iam create-open-id-connect-provider \
    --url "${OIDC_ISSUER}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "${THUMBPRINT}" \
    >/dev/null
fi

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

log "ensure AWS Load Balancer Controller IAM policy"
if ! aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document "file://${POLICY_FILE}" \
    >/dev/null
else
  printf 'Policy already exists: %s\n' "${POLICY_ARN}"
fi

TRUST_FILE="$(mktemp)"
cat > "${TRUST_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

log "ensure AWS Load Balancer Controller IRSA role"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_FILE}" \
    --tags \
      "Key=Project,Value=cloudsec-rbi" \
      "Key=Environment,Value=${ENVIRONMENT}" \
      "Key=ManagedBy,Value=bash" \
      "Key=Component,Value=aws-load-balancer-controller" \
    >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "file://${TRUST_FILE}" \
    >/dev/null
fi
rm -f "${TRUST_FILE}"

if ! aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
  --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyArn" \
  --output text | grep -q "${POLICY_ARN}"; then
  aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}"
fi

log "configure kubeconfig"
aws eks update-kubeconfig "${AWS_ARGS[@]}" --name "${CLUSTER_NAME}" >/dev/null

log "install or upgrade AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update eks >/dev/null

if [[ "${FORCE_REINSTALL}" == "1" ]]; then
  log "force reinstall requested; removing stale AWS Load Balancer Controller webhook material"
  helm uninstall aws-load-balancer-controller --namespace "${SERVICE_ACCOUNT_NAMESPACE}" >/dev/null 2>&1 || true
  kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found=true >/dev/null
  kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found=true >/dev/null
  kubectl -n "${SERVICE_ACCOUNT_NAMESPACE}" delete secret aws-load-balancer-tls --ignore-not-found=true >/dev/null
fi

HELM_ARGS=(
  upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller
  --namespace "${SERVICE_ACCOUNT_NAMESPACE}"
  --set "clusterName=${CLUSTER_NAME}"
  --set "region=${AWS_REGION}"
  --set "vpcId=${VPC_ID}"
  --set "serviceAccount.create=true"
  --set "serviceAccount.name=${SERVICE_ACCOUNT_NAME}"
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ROLE_ARN}"
  --wait
  --timeout 10m
)

if [[ -n "${CHART_VERSION}" ]]; then
  HELM_ARGS+=(--version "${CHART_VERSION}")
fi

helm "${HELM_ARGS[@]}"

log "verify AWS Load Balancer Controller"
kubectl -n "${SERVICE_ACCOUNT_NAMESPACE}" rollout restart "deployment/${SERVICE_ACCOUNT_NAME}" >/dev/null
kubectl -n "${SERVICE_ACCOUNT_NAMESPACE}" rollout status "deployment/${SERVICE_ACCOUNT_NAME}" --timeout=5m
kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null
printf 'AWS Load Balancer Controller is ready for cluster %s using role %s\n' "${CLUSTER_NAME}" "${ROLE_ARN}"
