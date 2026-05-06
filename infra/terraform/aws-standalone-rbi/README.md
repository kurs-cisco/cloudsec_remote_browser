# AWS Standalone RBI Terraform

This subtree contains the standalone AWS Terraform entrypoint for deploying
`cloudsec_remote_browser` as an RBI provider account that SWG can integrate
with like an external isolation provider.

In scope:

- Terraform remote state bootstrap resources.
- Production global foundation resources such as ECR repositories.
- Production regional VPC, ingress, Redis, and TURN infrastructure primitives.
- RBI-owned KMS keys, Secrets Manager secret metadata, mTLS certificate
  metadata, trust-bundle metadata, and rotation IAM scaffolding.
- EKS control-plane node groups, bare-metal Kata worker node groups, Kubernetes
  add-ons, `kata-clh` RuntimeClass, worker namespace, worker NetworkPolicy,
  worker pool Deployment, and suspended session Job template.
- Reusable modules with variables, outputs, and non-secret example tfvars files.

Secret values are intentionally out of scope for Terraform state. Terraform
creates secret containers, policies, and rotation hooks only. Bootstrap HMACs,
TURN shared secrets, mTLS client private keys, and runtime tokens must be
generated and rotated by a controlled secret bootstrap or rotation workflow.

## Layout

```text
bootstrap/remote-state                 # S3 and DynamoDB backend bootstrap
envs/prod/global                       # ECR/global foundation root
envs/prod/<region>/network             # VPC, ingress, Redis, TURN root
envs/prod/<region>/data                # KMS, secrets, mTLS, audit root
envs/prod/<region>/eks                 # EKS and Kata node groups root
envs/prod/<region>/apps                # Kubernetes add-ons and RBI app root
configs                                # Real shell-sourceable deployment configs
modules/ecr                            # ECR repositories
modules/eks                            # EKS cluster and standard nodes
modules/ingress                        # Public ALB and PrivateLink NLB
modules/k8s-addons                     # RuntimeClass and cluster add-ons
modules/kata-nodegroup                 # Bare-metal Kata worker node group
modules/kms                            # RBI-owned KMS keys and policies
modules/mtls                           # ACM public cert and PCA metadata
modules/network                        # VPC, subnets, NAT, VPC endpoints
modules/observability                  # Logs and EventBridge audit hooks
modules/rbi-apps                       # RBI namespaces and worker manifests
modules/redis                          # ElastiCache Redis replication group
modules/secrets                        # Secrets Manager metadata and policies
modules/turn                           # TURN EC2 ASG and NLB primitives
examples                               # Non-secret example tfvars
```

## Apply Order

1. Apply `bootstrap/remote-state` with local state.
2. Configure S3 backend settings for the `envs/prod/*` roots from the bootstrap outputs.
3. Apply `envs/prod/global`.
4. Apply `envs/prod/<region>/data`.
5. Apply `envs/prod/<region>/network`.
6. Apply `envs/prod/<region>/eks`.
7. Apply `envs/prod/<region>/apps`.

The production roots use an empty `backend "s3" {}` block so backend settings can be supplied with `terraform init -backend-config=...` and do not need to be committed.

## Region Model

The `modules/` directory is the generic Terraform implementation. The
`envs/prod/<region>/...` directories are thin root modules that create separate
state boundaries per region and component. That separation is intentional for
production because network, data, EKS, and apps can then be planned, locked,
rolled back, and promoted independently.

The checked-in `envs/prod/us-east-1/...` tree is the first concrete regional
instance. To deploy another region, use the same root shape with different
backend keys and regional inputs rather than forking module logic. The
`examples/deployment.env.example` file is region-neutral and can be sourced
with overrides:

```sh
RBI_REGION=us-west-2 \
RBI_ACCOUNT_ID=111122223333 \
SWG_ACCOUNT_ID=444455556666 \
RBI_DOMAIN=us-west-2.rbi.example.com \
source cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/examples/deployment.env.example
```

For `tfvars`-based workflows, start from
`examples/prod-regional-network.auto.tfvars.example` and replace the region,
AZs, CIDRs, certificate ARN, PrivateLink DNS name, and hostnames for the target
region.

## Deployment Environment Template

Use `examples/deployment.env.example` as the single shell-sourceable starting
point for deployment-time values across the standalone RBI roots. It contains
only placeholders and `TF_VAR_*` exports; secret values must still be created by
the RBI-owned bootstrap or rotation workflow after the Terraform secret
containers exist.

```sh
set -a
source cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/examples/deployment.env.example
set +a
```

For the current ap-south-1 development account, use the checked-in config:

```sh
set -a
source cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env
set +a
```

## Environment Management Script

Use the Bash scripts under `cloudsec_remote_browser/scripts/` to plan, deploy,
deploy only changed roots, redeploy, or destroy the standalone RBI roots in the
correct order. The scripts source a config file, initialize the S3 backend for
each non-bootstrap root, and create state keys under
`<environment>/<region>/<root>.tfstate`.

```sh
cd cloudsec_remote_browser

./scripts/rbi-plan.sh
./scripts/rbi-deploy.sh --root bootstrap
./scripts/rbi-deploy.sh --root global,data,network
./scripts/rbi-deploy-all.sh --auto-approve
./scripts/rbi-redeploy.sh --root apps --auto-approve
./scripts/rbi-destroy.sh --root apps --confirm-destroy --auto-approve
```

`rbi-deploy-all.sh` runs the roots in dependency order, creates a saved
Terraform plan for each selected root, skips roots whose plans have no changes,
and applies only the changed roots. Without `--auto-approve`, it asks for a
per-root `yes` confirmation before applying each saved plan.

The default config is
`infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env`.
Override it either with a positional config path or with `--config <path>` when
managing another account or region:

```sh
./scripts/rbi-plan.sh infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env
./scripts/rbi-deploy.sh cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --root bootstrap
./scripts/rbi-deploy-all.sh infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --root global,data,network
./scripts/rbi-deploy.sh --config infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --root global
```

Config paths may be absolute, relative to the current directory, relative to
`cloudsec_remote_browser`, or relative to the parent workspace.
Before the bootstrap state bucket exists, use `--local-backend` with `plan` to
dry-run non-bootstrap roots without remote backend initialization:

```sh
./scripts/rbi-plan.sh --root global,data,network,eks --local-backend
```

Destroy intentionally skips the bootstrap state bucket for `--root all`; pass
`--include-bootstrap` only when you also want to remove the state backend.

## SWG Integration Outputs

The roots expose the integration values SWG needs to consume this standalone RBI
provider:

- PrivateLink service name and private bootstrap DNS for `POST /api/swg/sessions`.
- Public handoff/viewer gateway DNS names.
- TURN URIs for viewer and worker ICE policy.
- RBI-owned Secrets Manager ARNs for SWG bootstrap HMAC and mTLS trust metadata.
- EKS cluster name, worker namespace, and `kata-clh` worker RuntimeClass.
