# Standalone RBI Image Builds

This tree holds Packer-compatible image scaffolding for standalone RBI runtime
artifacts. The Terraform roots consume promoted artifacts through environment
variables or SSM Parameter Store; secrets are not stored in Terraform state.

## SSM Promotion Contract

`cloudsec_remote_browser/scripts/manage-rbi-env.sh` already hydrates placeholder
AMI and mutable image values from these SSM defaults:

- TURN AMI: `/cloudsec-rbi/<environment>/<region>/images/turn-ami-id`
- Kata worker AMI: `/cloudsec-rbi/<environment>/<region>/images/kata-worker-ami-id`
- Control-plane image digest: `/cloudsec-rbi/<environment>/<region>/images/control-plane-image-digest`
- Session Authority image digest: `/cloudsec-rbi/<environment>/<region>/images/session-authority-image-digest`
- Media gateway image digest: `/cloudsec-rbi/<environment>/<region>/images/media-gateway-image-digest`
- File broker image digest: `/cloudsec-rbi/<environment>/<region>/images/file-broker-image-digest`
- Clipboard broker image digest: `/cloudsec-rbi/<environment>/<region>/images/clipboard-broker-image-digest`
- Worker image digest: `/cloudsec-rbi/<environment>/<region>/images/worker-image-digest`

Override `RBI_TURN_AMI_ID_SSM_PARAMETER`,
`RBI_KATA_WORKER_AMI_ID_SSM_PARAMETER`, or `RBI_IMAGE_SSM_PREFIX` in the sourced
deployment config when an account needs a different promotion path.

## Build Entrypoints

From `cloudsec_remote_browser`:

```bash
./scripts/rbi-build-amis.sh --config infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --build-promote
./scripts/rbi-build-images.sh --config infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --build-promote
```

Both scripts write artifact env files under `images/artifacts/` by default.
Use `--promote --artifact-env <file>` to promote previously built artifacts
without rebuilding.

## Secret Handling

The TURN AMI bakes Docker, a coturn runtime service, and the startup script. It
does not bake the TURN shared secret. At boot the service reads the secret from
an SSM SecureString parameter or Secrets Manager secret named in
`/etc/cloudsec-rbi/turn.env`.

The Kata worker AMI bakes the host bootstrap script expected by the Terraform
launch-template user data:

```text
/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh
```

The Packer provisioner validates KVM, Kata shims, Cloud Hypervisor, containerd
runtime registration, and the bootstrap script path before producing an AMI.
