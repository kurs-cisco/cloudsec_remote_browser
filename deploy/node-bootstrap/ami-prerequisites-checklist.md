# AMI Prerequisites Checklist

Use this checklist when building the dedicated Wave 3 worker AMI for the
bare-metal EKS Kata node group.

## Base image

- Start from an EKS-optimized worker AMI lineage rather than a generic EC2 base.
- Prefer Amazon Linux 2023. Amazon EKS stopped publishing EKS-optimized AL2
  AMIs on November 26, 2025.
- Keep the EKS join tooling that ships with the base image. On AL2023 that
  means `nodeadm`; do not replace it with an ad hoc join script.
- Do not perform an in-place major OS upgrade on top of the EKS base image.

## Hardware and kernel

- Use x86_64 bare-metal instance types for the first Kata worker tier.
- Confirm hardware virtualization is exposed and `/dev/kvm` is available.
- Keep the kernel and kernel modules aligned with the EKS-optimized AMI build;
  avoid drifting `kubelet`, `containerd`, or CNI bits outside the base image's
  tested matrix.
- Ensure these modules are available in the image:
  - `kvm`
  - `kvm_intel` or `kvm_amd`
  - `vhost_vsock`
  - `overlay`
  - `br_netfilter`

## Container runtime and Kata stack

- Install Kata Containers with a `kata-clh` capable runtime handler.
- Install Cloud Hypervisor on the image and validate the binary path.
- Install the appropriate Kata shim binary:
  - `containerd-shim-kata-clh-v2`, or
  - `containerd-shim-kata-v2` with a matching `io.containerd.kata-clh.v2`
    runtime type.
- Make sure the containerd config path used by `nodeadm` can accept the extra
  runtime stanza from `user-data/al2023-kata-worker-user-data.mime`.
- Validate that `ctr` and `containerd` are present and healthy before snapshotting
  the AMI.

## Bootstrap assets

- Bake `scripts/bootstrap-kata-worker-host.sh` into the image at
  `/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh`, or update the
  user-data template to call the actual installed path.
- For EKS managed node groups on AL2023 custom AMIs, expect to pass the
  rendered MIME multi-part user-data through an EC2 launch template rather than
  an AL2-era `overrideBootstrapCommand`.
- Create `/opt/cloudsec/node-bootstrap` with root ownership and `0755`
  permissions.
- Keep the user-data render process in IaC so cluster coordinates and taints are
  environment-specific, not hard-coded in the AMI.

## Identity, logging, and packages

- Attach only the IAM permissions required for node registration, image pulls,
  logging, and explicit worker dependencies.
- Forward `journald`, `containerd`, `nodeadm`, and `kubelet` logs to the
  standard platform sink.
- Preinstall any SSM or break-glass agent required by operations; disable SSH by
  default unless policy requires it.
- Preload trust anchors, registry mirror certificates, and proxy configuration
  if worker egress is forced through private infrastructure.

## Pre-promotion validation

- Boot the AMI in the intended bare-metal family and confirm:
  - `systemctl status containerd`
  - `ls -l /dev/kvm`
  - `cloud-hypervisor --version`
  - `grep -R "runtimes.kata-clh" /etc/containerd`
- Join a staging EKS cluster using the rendered user-data template.
- Launch a test pod with `runtimeClassName: kata-clh` and verify it schedules
  only on the worker-plane nodes.
- Reboot the node and confirm the modules, sysctls, and runtime registration
  persist.
