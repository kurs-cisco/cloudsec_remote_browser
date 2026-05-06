# Wave 3 Kata/EKS Live Proof Runbook

This runbook turns the Wave 3 scaffolding into an executable proof path for a
Kata-backed RBI worker plane on EKS. It is safe to run the offline checks without
AWS credentials. The live steps require a kubeconfig for the target EKS cluster.

## Offline Validation

Run these before touching AWS:

```bash
cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh offline
cloudsec_remote_browser/deploy/node-bootstrap/scripts/rbi-worker-ami-image-pipeline.sh check
cloudsec_remote_browser/deploy/node-bootstrap/scripts/rbi-worker-ami-image-pipeline.sh inputs
```

Expected result:

- `kubectl kustomize` succeeds for `deploy/eks` and `deploy/eks/proof`.
- `kubectl kustomize` succeeds for `deploy/eks/proof/egress`.
- Shell syntax checks pass for the render, validation, proof, and bootstrap
  scripts, and the worker egress proof Python script parses successfully.
- Static egress checks prove the worker NetworkPolicy has no broad `0.0.0.0/0`
  direct egress and only allows DNS, control, media/TURN, and SWG proxy targets by
  labels and ports.
- Static proof checks prove the egress proof Job runs the worker image under
  `runtimeClassName: kata-clh` in `cloudsec-rbi-workers`, inherits the worker
  shared ConfigMap, and mounts the Python stdlib proof script.
- Render validation proves default labels, taints, IMDSv2, and launch-template
  wiring without AWS credentials.

## AMI and Worker Image Promotion

Use `deploy/node-bootstrap/scripts/rbi-worker-ami-image-pipeline.sh emit-commands`
as the CI/IaC checklist. The promotion is intentionally split into immutable
artifacts:

- custom AL2023 EKS AMI with Kata, Cloud Hypervisor, containerd runtime handler,
  and `/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh`;
- signed worker image digest;
- rendered AL2023 `nodeadm` user-data;
- EC2 launch template version;
- EKS managed nodegroup referencing that launch-template version.

The minimum AMI proof before creating the nodegroup is:

```bash
cloud-hypervisor --version
ls -l /dev/kvm
grep -R "runtimes.kata-clh" /etc/containerd
systemctl status containerd
```

## Render Cluster Inputs

Collect the EKS cluster coordinates:

```bash
aws eks describe-cluster \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.{endpoint:endpoint,ca:certificateAuthority.data,cidr:kubernetesNetworkConfig.serviceIpv4Cidr}'
```

Render launch-template and nodegroup inputs:

```bash
export AWS_REGION=us-east-1
export EKS_CLUSTER_NAME=replace-with-cluster-name
export EKS_API_SERVER_ENDPOINT=https://replace.eks.amazonaws.com
export EKS_CERTIFICATE_AUTHORITY_B64=replace-with-base64-ca
export EKS_SERVICE_IPV4_CIDR=10.100.0.0/16
export RBI_AMI_ID=ami-0123456789abcdef0
export RBI_INSTANCE_TYPE=c5.metal
export RBI_SECURITY_GROUP_IDS_JSON='["sg-0123456789abcdef0"]'
export RBI_LAUNCH_TEMPLATE_NAME=cloudsec-rbi-workers
export RBI_LAUNCH_TEMPLATE_VERSION=1

cloudsec_remote_browser/deploy/eks/render-rbi-worker-launch-template.sh
```

## Create Worker Plane

Create or rotate the launch template:

```bash
aws ec2 create-launch-template \
  --cli-input-json file://cloudsec_remote_browser/deploy/eks/rendered/rbi-worker-launch-template-data.json
```

Create the managed nodegroup:

```bash
eksctl create nodegroup \
  -f cloudsec_remote_browser/deploy/eks/rendered/rbi-worker-nodegroup.eksctl.yaml
```

Apply the Kubernetes worker-plane resources after replacing secrets and image
values:

```bash
kubectl apply -f cloudsec_remote_browser/deploy/eks/rbi-worker-namespace.yaml
kubectl apply -f cloudsec_remote_browser/deploy/eks/rbi-worker-secrets.example.yaml
kubectl apply -k cloudsec_remote_browser/deploy/eks
```

Before scaling workers, make sure the real control-plane, media gateway, TURN, and
SWG proxy deployments carry the labels referenced by
`deploy/eks/rbi-worker-network-policy.yaml`. The shared worker ConfigMap should point
`HTTP_PROXY`, `HTTPS_PROXY`, and `SWG_EGRESS_PROXY_URL` at the labeled SWG proxy
service.

## Live Proof

Validate the RuntimeClass and nodegroup contract:

```bash
KUBECTL_CONTEXT=cloudsec-rbi-ap-south-1 \
  cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh live
```

Run the Kata proof pod:

```bash
KUBECTL_CONTEXT=cloudsec-rbi-ap-south-1 \
  cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh apply-proof
```

The proof pod must:

- schedule only on nodes with
  `cloudsec.cisco.com/rbi-worker-plane=true` and
  `cloudsec.cisco.com/node-pool=rbi-workers`;
- tolerate only `cloudsec.cisco.com/rbi-worker-plane=true:NoSchedule`;
- use `runtimeClassName: kata-clh`;
- complete successfully without `/dev/kvm` visible inside the container.

Run the worker-image egress proof after the worker namespace, shared ConfigMap,
ServiceAccount, NetworkPolicy, and real control/media/TURN/SWG proxy targets are
applied:

```bash
KUBECTL_CONTEXT=cloudsec-rbi-ap-south-1 \
  cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh preflight-egress

KUBECTL_CONTEXT=cloudsec-rbi-ap-south-1 \
  cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh apply-egress-proof
```

`apply-egress-proof` runs the same live preflight before creating the Job. It fails
without applying anything if the live worker NetworkPolicy still allows broad
`0.0.0.0/0` direct egress, still uses `ipBlock` CIDRs, or if the live worker shared
ConfigMap is missing SWG proxy, control WSS, media WSS, or UDP TURN values.

The proof Job runs `cloudsec-remote-browser-worker:latest` with
`deploy/eks/proof/egress/scripts/rbi_worker_egress_proof.py` mounted from a ConfigMap.
Use the `deploy/eks/proof/egress` kustomization image transformer to replace the
worker image tag with the promoted digest before running against a real cluster.

The egress proof must:

- prove direct public HTTPS to `https://example.com/` fails while the same HTTPS
  request through `SWG_EGRESS_PROXY_URL` succeeds;
- prove direct metadata, Kubernetes API, Redis, private CIDR, and `8.8.8.8:53`
  probes fail without using proxy environment variables;
- prove metadata and private CIDR URLs sent through the SWG proxy are denied;
- prove worker control WSS, media gateway WSS, and TURN UDP/STUN reachability
  through the labeled in-cluster targets allowed by the worker NetworkPolicy.

Override proof targets in a cluster-specific overlay or by editing the proof Job
manifest before apply when the live cluster uses different service names. The most
common override is `EGRESS_PROOF_REDIS_TARGET=replace-with-redis-hostname:6379`.

Collect evidence:

```bash
kubectl get runtimeclass kata-clh -o yaml
kubectl get nodes -l cloudsec.cisco.com/rbi-worker-plane=true --show-labels
kubectl describe node -l cloudsec.cisco.com/rbi-worker-plane=true
kubectl -n cloudsec-rbi-kata-proof logs pod/kata-runtimeclass-proof
kubectl -n cloudsec-rbi-kata-proof get pod kata-runtimeclass-proof -o yaml
kubectl -n cloudsec-rbi-workers logs job/rbi-worker-egress-proof --all-containers=true
kubectl -n cloudsec-rbi-workers get job rbi-worker-egress-proof -o yaml
```

Cleanup:

```bash
kubectl delete -k cloudsec_remote_browser/deploy/eks/proof
kubectl -n cloudsec-rbi-workers delete job/rbi-worker-egress-proof --ignore-not-found
kubectl -n cloudsec-rbi-workers delete configmap/rbi-worker-egress-proof-script --ignore-not-found
```
