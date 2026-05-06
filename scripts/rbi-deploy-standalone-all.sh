#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Deploy the standalone RBI environment end-to-end.

Usage:
  scripts/rbi-deploy-standalone-all.sh [config-file] [options]

Options:
  config-file        Env config file to source.
  --config <path>    Env config file to source.
  --auto-approve     Pass --auto-approve to Terraform apply steps.
  --skip-preflight   Skip the initial warning-only preflight.
  -h, --help         Show help.

This is a convenience wrapper around:
  scripts/rbi-bootstrap-ci.sh --stage full

The full sequence is:
  preflight -> backend bootstrap/skip -> identity -> global -> images -> data
  -> secrets -> amis -> hard preflight -> network -> eks -> apps -> proof

With RBI_MANAGE_TF_BACKEND=0, backend bootstrap is skipped and the existing
TF_STATE_BUCKET/TF_LOCK_TABLE backend from the config is used.
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

exec "${SCRIPT_DIR}/rbi-bootstrap-ci.sh" "$@" --stage full
