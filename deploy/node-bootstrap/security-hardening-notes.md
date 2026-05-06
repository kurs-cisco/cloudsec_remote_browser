# Security Hardening Notes

These notes are for the dedicated bare-metal EKS worker nodes that back the RBI
Kata plane. They complement, but do not replace, the namespace, RuntimeClass,
and network policy scaffolding already present in `deploy/eks`.

## Node group isolation

- Keep the RBI worker plane on a separate bare-metal node group from the control
  plane and from non-RBI workloads.
- Enforce the taint and label pair used by `deploy/eks/kata-runtimeclass.yaml`:
  `cloudsec.cisco.com/rbi-worker-plane=true`.
- Use dedicated security groups and subnets for worker nodes; do not share broad
  east-west trust with general compute pools.

## Host lockdown

- Require IMDSv2 and set hop limit to the minimum that still supports node
  bootstrap.
- Prefer no public IPs on worker nodes.
- Disable SSH by default. If break-glass SSH is unavoidable, gate it behind
  short-lived access workflows and full session logging.
- Keep SELinux or the platform MAC system enabled when supported by the chosen
  AMI baseline.
- Apply the host sysctls from `scripts/bootstrap-kata-worker-host.sh` and manage
  them as code.

## Runtime and pod restrictions

- Do not allow privileged worker pods.
- Block `hostPath`, `hostPID`, `hostNetwork`, and Docker socket style mounts for
  RBI workloads.
- Require `runtimeClassName: kata-clh` for the worker tier.
- Keep seccomp, AppArmor, or SELinux policy enabled for both the host and the
  guest container workload where the platform supports it.
- Use read-only root filesystems and minimal Linux capabilities for worker pods.

## Network and egress controls

- Default-deny east-west network access from worker pods and worker nodes.
- Route internet egress through the approved SWG or egress proxy path.
- Block metadata, RFC1918, and other internal control-plane ranges except for
  explicitly approved dependencies.
- Keep DNS resolution on the approved resolver path only; do not allow arbitrary
  recursive DNS from worker workloads.

## Secrets and identity

- Prefer IRSA or EKS Pod Identity over node-wide credentials for brokered
  services.
- Keep node IAM roles narrow and separate from control-plane roles.
- Avoid placing long-lived secrets in user-data. Use user-data only for cluster
  coordinates and bootstrap wiring.
- If runtime attestation is added later, make secret release contingent on that
  attestation result rather than only on node membership.

## Supply chain and integrity

- Sign worker images and enforce signature verification before rollout.
- Generate SBOMs for the AMI and worker image.
- Version Kata, Cloud Hypervisor, and Chromium inputs explicitly in the AMI
  pipeline.
- Treat the host bootstrap script and user-data template as reviewed release
  artifacts, not one-off operator edits.

## Detection and recovery

- Alert on unexpected runtime handlers, missing `/dev/kvm`, or worker nodes that
  lose the `cloudsec.cisco.com/rbi-worker-plane=true` label.
- Capture `nodeadm`, `containerd`, `kubelet`, and kernel logs during failed boot
  attempts.
- Rebuild compromised or drifted nodes from a clean AMI instead of repairing
  them manually in place.
- Exercise node termination and session cleanup regularly so Wave 3 teardown
  guarantees remain true in production.
