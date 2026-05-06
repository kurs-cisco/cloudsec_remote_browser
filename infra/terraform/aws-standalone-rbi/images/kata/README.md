# Kata Worker AMI

This Packer scaffold builds an AL2023 EKS worker AMI for the dedicated RBI
worker node group. The image bakes:

- Kata Containers runtime shims;
- Cloud Hypervisor;
- containerd runtime entries for `kata-clh` and `kata`;
- host kernel module/sysctl defaults needed by the worker plane;
- `/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh`, which the
  Terraform launch-template user data invokes after `nodeadm`.

The installer first tries package-manager installs and then configurable RPM or
archive URLs:

- `KATA_RPM_URLS`
- `KATA_STATIC_TARBALL_URL`
- `CLOUD_HYPERVISOR_RPM_URL`
- `CLOUD_HYPERVISOR_BINARY_URL`

Real builds should pin these inputs to vetted, mirrored artifacts and run on a
bare-metal Packer build instance so `/dev/kvm` validation is meaningful.

Prefer `cloudsec_remote_browser/scripts/rbi-build-amis.sh` for normal builds and
promotion to the SSM parameter consumed by the deployment scripts.
