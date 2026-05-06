# EKS Kata Worker Plane

Concrete Wave 3 worker-plane artifacts for running Kata-backed RBI workers on EKS.
This directory now contains:

- `rbi-worker-nodegroup.eksctl.yaml`: `eksctl` example for the dedicated bare-metal
  worker node group. This is a template rendered against the launch-template name
  and version created for the custom AL2023 AMI.
- `rbi-worker-launch-template-data.json`: AWS CLI launch-template input template for
  the AL2023 custom worker AMI
- `render-rbi-worker-launch-template.sh`: renders the launch-template JSON, AL2023
  MIME user-data, and the `eksctl` nodegroup config from one environment block
- `kata-runtimeclass.yaml`: default `kata-clh` `RuntimeClass` for worker pods
- `rbi-worker-namespace.yaml`: restricted namespace for the worker plane
- `rbi-worker-serviceaccount.yaml`: dedicated worker identity with service-account
  token automount disabled
- `rbi-worker-shared-configmap.yaml`: one edit point for the shared worker-plane
  gateway, TURN, and display settings
- `rbi-worker-network-policy.yaml`: deny-by-default worker policy with DNS,
  control-plane, media/TURN, and SWG proxy egress only by labels and ports
- `rbi-worker-pool-deployment.yaml`: warm-pool `Deployment` template using
  `WORKER_MODE=pool`
- `rbi-session-worker-job.yaml`: per-session `Job` template using
  `WORKER_MODE=session`
- `rbi-worker-secrets.example.yaml`: placeholder `Secret` objects for the pool and
  session worker flows
- `proof/`: live-cluster proof manifests for a small `kata-clh` pod that schedules
  on the dedicated worker node contract
- `scripts/prove-rbi-worker-node-contract.sh`: live node label and taint proof for
  the dedicated worker node group
- `scripts/validate-wave3-kata-eks.sh`: offline and live validation wrapper for
  shell syntax, kustomize rendering, RuntimeClass checks, node contract proof, and
  proof-pod execution
- `kustomization.yaml`: one entry point for the Kubernetes resources in this folder

## Dedicated Node Contract

The Kubernetes manifests and the `eksctl` nodegroup file assume a dedicated worker pool
with these scheduling markers:

- Node label `cloudsec.cisco.com/rbi-worker-plane=true`
- Node label `cloudsec.cisco.com/node-pool=rbi-workers`
- Taint `cloudsec.cisco.com/rbi-worker-plane=true:NoSchedule`

Use labels you control instead of matching `node.kubernetes.io/instance-type`; on EKS,
that label is the full instance type such as `c5.metal` or `m5zn.metal`, not a generic
`metal` value.

## Pod Hardening Baseline

The worker templates are wired for the minimum hardening expected for the Kata plane:

- `runtimeClassName: kata-clh`
- `runAsNonRoot: true`
- `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`
- `seccompProfile: RuntimeDefault`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `readOnlyRootFilesystem: true`
- `automountServiceAccountToken: false`
- explicit writable `emptyDir` volumes for `/tmp`, `/dev/shm`, and `/home/rbi`

## Worker Egress Lockdown

The worker namespace is deny-by-default for egress. Workers do not get direct
`0.0.0.0/0` internet egress. The NetworkPolicy allows only these labeled
destinations on explicit ports:

- CoreDNS in `kube-system`, TCP/UDP 53
- control-plane pods with `cloudsec.cisco.com/rbi-plane=control`, TCP 443, 8080,
  and 18081
- media gateway pods with `cloudsec.cisco.com/rbi-plane=media` and
  `app.kubernetes.io/component=media-gateway`, TCP 443, 8443, and 18082
- TURN pods with `cloudsec.cisco.com/rbi-plane=media` and
  `app.kubernetes.io/component=turn`, UDP/TCP 3478 and TCP 443/5349
- SWG proxy pods in namespaces labeled `cloudsec.cisco.com/egress-plane=swg`
  with `app.kubernetes.io/component=swg-proxy`, TCP 80, 443, and 3128

Keep the namespace and pod labels on the real control, media, TURN, and SWG proxy
deployments in sync with `rbi-worker-network-policy.yaml`. Browser web traffic is
expected to use the SWG proxy defaults in `rbi-worker-shared-configmap.yaml`; direct
target-site sockets are denied by default.

## AL2023 Nodegroup Shape

The worker plane should now be executed as:

1. custom AL2023 Kata AMI
2. EC2 launch template carrying the rendered MIME user-data
3. EKS managed nodegroup that references that launch template

This replaces the older AL2-style `/etc/eks/bootstrap.sh` path. AWS currently
documents AL2023 custom managed node groups as a launch-template based flow,
while `overrideBootstrapCommand` is not supported for AL2023 custom AMIs.

## Bootstrap Flow

1. Build the custom Kata AMI and bake in
   `/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh`.

   Supporting docs:

   - `../node-bootstrap/README.md`
   - `../node-bootstrap/ami-prerequisites-checklist.md`
   - `../node-bootstrap/security-hardening-notes.md`

2. Build and publish the worker image.

   ```bash
   cd cloudsec_remote_browser
   docker build -t cloudsec-remote-browser-worker ./worker
   ```

3. Collect the explicit AL2023 cluster metadata that `nodeadm` requires.

   ```bash
   aws eks describe-cluster \
     --name "$EKS_CLUSTER_NAME" \
     --region "$AWS_REGION" \
     --query 'cluster.{endpoint:endpoint,ca:certificateAuthority.data,cidr:kubernetesNetworkConfig.serviceIpv4Cidr}'
   ```

4. Render the launch-template payloads and the `eksctl` nodegroup config.

   ```bash
   export EKS_CLUSTER_NAME=replace-with-cluster-name
   export AWS_REGION=us-east-1
   export EKS_API_SERVER_ENDPOINT=https://XXXXXXXX.gr7.us-east-1.eks.amazonaws.com
   export EKS_CERTIFICATE_AUTHORITY_B64=replace-with-base64-ca
   export EKS_SERVICE_IPV4_CIDR=10.100.0.0/16
   export RBI_AMI_ID=ami-0123456789abcdef0
   export RBI_INSTANCE_TYPE=c5.metal
   export RBI_SECURITY_GROUP_IDS_JSON='["sg-0123456789abcdef0"]'
   export RBI_LAUNCH_TEMPLATE_NAME=cloudsec-rbi-workers

   cloudsec_remote_browser/deploy/eks/render-rbi-worker-launch-template.sh
   ```

   The script writes these rendered files under
   `cloudsec_remote_browser/deploy/eks/rendered/` by default:

   - `rbi-worker-user-data.mime`
   - `rbi-worker-launch-template-data.json`
   - `rbi-worker-nodegroup.eksctl.yaml`

5. Create the EC2 launch template from the rendered JSON.

   ```bash
   aws ec2 create-launch-template \
     --cli-input-json file://cloudsec_remote_browser/deploy/eks/rendered/rbi-worker-launch-template-data.json
   ```

   For later AMI rotations, create a new launch-template version and update the
   nodegroup to that version instead of creating a new nodegroup.

6. Create the worker namespace first so secret creation has a target namespace.

   ```bash
   kubectl apply -f cloudsec_remote_browser/deploy/eks/rbi-worker-namespace.yaml
   ```

7. Replace the placeholder values in `rbi-worker-secrets.example.yaml`, then apply
   the secrets.

   ```bash
   kubectl apply -f cloudsec_remote_browser/deploy/eks/rbi-worker-secrets.example.yaml
   ```

8. Update `rbi-worker-shared-configmap.yaml` for the real media-gateway, TURN, SWG
   proxy service, and display settings, and set the worker image in
   `kustomization.yaml`.

   Image changes now happen in one place:

   ```bash
   cd cloudsec_remote_browser/deploy/eks
   kustomize edit set image cloudsec-remote-browser-worker=123456789012.dkr.ecr.us-east-1.amazonaws.com/cloudsec-remote-browser-worker:prod_r1234
   ```

9. Create the EKS managed nodegroup from the rendered template.

   ```bash
   eksctl create nodegroup \
     -f cloudsec_remote_browser/deploy/eks/rendered/rbi-worker-nodegroup.eksctl.yaml
   ```

10. Apply the Kubernetes resources in this directory.

   ```bash
   kubectl apply -k cloudsec_remote_browser/deploy/eks
   ```

11. Prove the RuntimeClass and dedicated worker node contract.

   Offline, without AWS credentials:

   ```bash
   cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh offline
   ```

   Live, after the nodegroup joins:

   ```bash
   cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh live
   cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh apply-proof
   ```

   The `apply-proof` mode applies `proof/`, waits for the `kata-clh` pod to
   complete, and prints the proof logs.

12. Make one of the worker modes live:

   - warm pool:

     ```bash
     kubectl -n cloudsec-rbi-workers scale deployment/rbi-worker-pool-template --replicas=2
     ```

   - single pre-assigned session:

     ```bash
     kubectl -n cloudsec-rbi-workers patch job/rbi-session-worker-template \
       --type merge \
       -p '{"spec":{"suspend":false}}'
     ```

The `Deployment` starts at `replicas: 0` and the `Job` starts with `spec.suspend: true`
so the directory can be applied safely before the real image, worker token, and gateway
values are in place.

## Notes

- `rbi-worker-nodegroup.eksctl.yaml` and `rbi-worker-launch-template-data.json` are not
  part of `kustomization.yaml` because they are cluster-infrastructure inputs for
  `eksctl` and `aws ec2`, not Kubernetes resources.
- The worker network policy now allows CoreDNS, control-plane, media gateway, TURN,
  and SWG proxy destinations explicitly; without the SWG proxy path, workers cannot
  reach target sites.
- Shared worker-plane runtime values now live in `rbi-worker-shared-configmap.yaml`.
  Only pool/session-specific values remain inline in the `Deployment` and `Job`.
  The proxy defaults are placeholders and should point at the regional SWG proxy
  service selected for this worker plane.
- The templates pin `1000:1000` for the pod security context so restricted admission
  does not depend on kubelet resolving the image's named `rbi` user. If the worker image
  is rebuilt with a different numeric UID/GID, keep the manifests in sync.
- AMI and worker-image promotion are now tracked by
  `../node-bootstrap/scripts/rbi-worker-ami-image-pipeline.sh` and
  `../../docs/wave3-kata-eks-live-proof-runbook.md`. The script is executable
  without AWS credentials and emits the AWS/EKS command sequence for CI or IaC
  adaptation.
