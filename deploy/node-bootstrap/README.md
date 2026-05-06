# Wave 3 Node Bootstrap Scaffolding

This subtree fills the host-side gap called out by `deploy/eks/README.md`: the
cluster-side worker manifests now have an execution path, and this directory
holds the AMI and host-bootstrap side of that flow.

## Contents

- `user-data/al2023-kata-worker-user-data.mime`: launch template user-data
  template for Amazon Linux 2023 based EKS worker nodes. It provides a
  `nodeadm` `NodeConfig` plus a shell hook for host validation and hardening.
- `scripts/bootstrap-kata-worker-host.sh`: host bootstrap script to bake into
  the custom AMI or inject with IaC. It persists kernel modules, applies basic
  sysctls, and verifies KVM/Kata prerequisites.
- `scripts/rbi-worker-ami-image-pipeline.sh`: executable AMI/image promotion
  checklist that validates local artifacts without AWS credentials and emits the
  real build, launch-template, nodegroup, and proof commands for CI/IaC.
- `ami-prerequisites-checklist.md`: build-time checklist for the custom AMI.
- `security-hardening-notes.md`: operational hardening notes for the dedicated
  bare-metal worker node group.

Companion execution artifacts now live in `../eks`:

- `../eks/render-rbi-worker-launch-template.sh`
- `../eks/rbi-worker-launch-template-data.json`
- `../eks/rbi-worker-nodegroup.eksctl.yaml`

## Why AL2023 First

Amazon EKS stopped publishing EKS-optimized AL2 AMIs on November 26, 2025, and
Amazon Linux 2023 based nodes use `nodeadm` instead of `/etc/eks/bootstrap.sh`.
Wave 3 scaffolding should therefore treat AL2023 as the primary path and AL2 as
compatibility-only.

## Assumptions

- The worker plane runs on dedicated bare-metal EKS nodes.
- The custom AMI is derived from an EKS-optimized base and keeps the EKS join
  machinery (`nodeadm` on AL2023).
- Kata Containers and Cloud Hypervisor are installed during the AMI build, not
  at first boot.
- Cluster-facing manifests from `../eks` are applied separately.

## Minimal rollout flow

1. Build a custom EKS worker AMI using the checklist in
   `ami-prerequisites-checklist.md`.
2. Bake `scripts/bootstrap-kata-worker-host.sh` into the image at
   `/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh`, or render the
   same script into the launch template user-data.
3. Render the launch-template input and AL2023 MIME user-data with
   `../eks/render-rbi-worker-launch-template.sh`.
4. Validate or emit the AMI/image promotion sequence with
   `scripts/rbi-worker-ami-image-pipeline.sh check` or
   `scripts/rbi-worker-ami-image-pipeline.sh emit-commands`.
5. Create the EC2 launch template using the rendered
   `../eks/rbi-worker-launch-template-data.json`.
6. Create the dedicated worker node group using the rendered
   `../eks/rbi-worker-nodegroup.eksctl.yaml`.
7. Apply the existing `../eks/kata-runtimeclass.yaml`,
   `../eks/rbi-worker-namespace.yaml`,
   `../eks/rbi-worker-network-policy.yaml`, and worker templates.
8. Verify the dedicated worker node group exposes the expected taint and labels
   with `../eks/scripts/validate-wave3-kata-eks.sh live`:
   `cloudsec.cisco.com/rbi-worker-plane=true:NoSchedule`,
   `cloudsec.cisco.com/rbi-worker-plane=true`, and
   `cloudsec.cisco.com/node-pool=rbi-workers`.

## Template inputs

The user-data template expects the following substitutions:

- `__EKS_CLUSTER_NAME__`
- `__EKS_API_SERVER_ENDPOINT__`
- `__EKS_CERTIFICATE_AUTHORITY_B64__`
- `__EKS_SERVICE_IPV4_CIDR__`
- `__RBI_NODE_LABELS__`
- `__RBI_NODE_TAINTS__`
- `__HOST_BOOTSTRAP_SCRIPT_PATH__`

## Smoke checks

After a node boots, validate:

- `journalctl -u nodeadm -u containerd -u kubelet -n 200`
- `grep -R \"runtimes.kata-clh\" /etc/containerd`
- `ls -l /dev/kvm`
- `kubectl get nodes -l cloudsec.cisco.com/rbi-worker-plane=true`
- `kubectl describe runtimeclass kata-clh`
- `../eks/scripts/validate-wave3-kata-eks.sh apply-proof`

## AL2 fallback

If a tenant or test lane still uses AL2, reuse the host bootstrap script but
wire your own AL2-specific user-data around `/etc/eks/bootstrap.sh`. Do not
fork this subtree back toward AL2 as the primary path.
