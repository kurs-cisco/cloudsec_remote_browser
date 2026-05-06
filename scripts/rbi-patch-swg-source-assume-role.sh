#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  rbi-patch-swg-source-assume-role.sh --profile PROFILE --principal-type user|role --principal-name NAME [options]

Options:
  --target-role-arn ARN     RBI secret-reader role to allow. Required unless RBI_AUTH_SIGN_ROLE_ARN is set.
  --policy-name NAME        Inline policy name. Defaults to AllowAssumeCloudsecRbiSecretReader.
  --region REGION           AWS region for CLI calls. Defaults to AWS_REGION/AWS_DEFAULT_REGION/us-west-2.

This patches the SWG/source-side identity policy required by AWS STS.
The RBI account role trust policy alone is not enough; the source user/role must
also have identity-side permission to call sts:AssumeRole on the RBI reader role.
USAGE
}

profile=""
principal_type=""
principal_name=""
target_role_arn="${RBI_AUTH_SIGN_ROLE_ARN:-}"
policy_name="${RBI_SWG_SOURCE_ASSUME_POLICY_NAME:-AllowAssumeCloudsecRbiSecretReader}"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:?missing --profile value}"
      shift 2
      ;;
    --principal-type)
      principal_type="${2:?missing --principal-type value}"
      shift 2
      ;;
    --principal-name)
      principal_name="${2:?missing --principal-name value}"
      shift 2
      ;;
    --target-role-arn)
      target_role_arn="${2:?missing --target-role-arn value}"
      shift 2
      ;;
    --policy-name)
      policy_name="${2:?missing --policy-name value}"
      shift 2
      ;;
    --region)
      region="${2:?missing --region value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$profile" || -z "$principal_type" || -z "$principal_name" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "$target_role_arn" ]]; then
  echo "--target-role-arn or RBI_AUTH_SIGN_ROLE_ARN is required" >&2
  usage >&2
  exit 2
fi

if [[ "$principal_type" != "user" && "$principal_type" != "role" ]]; then
  echo "--principal-type must be user or role" >&2
  exit 2
fi

policy_document="$(mktemp)"
trap 'rm -f "$policy_document"' EXIT

cat >"$policy_document" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumeCloudsecRbiSecretReader",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "${target_role_arn}"
    }
  ]
}
POLICY

echo "[rbi-patch-swg-source-assume-role] validating source caller for profile ${profile}" >&2
aws --profile "$profile" --region "$region" sts get-caller-identity >/dev/null

if [[ "$principal_type" == "user" ]]; then
  echo "[rbi-patch-swg-source-assume-role] attaching ${policy_name} to IAM user ${principal_name}" >&2
  aws --profile "$profile" --region "$region" iam put-user-policy \
    --user-name "$principal_name" \
    --policy-name "$policy_name" \
    --policy-document "file://${policy_document}"
else
  echo "[rbi-patch-swg-source-assume-role] attaching ${policy_name} to IAM role ${principal_name}" >&2
  aws --profile "$profile" --region "$region" iam put-role-policy \
    --role-name "$principal_name" \
    --policy-name "$policy_name" \
    --policy-document "file://${policy_document}"
fi

echo "[rbi-patch-swg-source-assume-role] patched ${principal_type} ${principal_name} for ${target_role_arn}" >&2
