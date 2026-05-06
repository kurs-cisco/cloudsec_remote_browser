# TURN AMI

The TURN image follows the behavior of
`browser_isolation/infra/aws/userdata/coturn.sh.tftpl`:

- install and enable Docker;
- discover the public IPv4 address through IMDSv2 at runtime unless
  `TURN_EXTERNAL_IP` is provided;
- pull `coturn/coturn:4.6`;
- run coturn on the host network with REST auth secret mode, fingerprint,
  stale nonce, no CLI, and the configured relay port range.

The shared secret is intentionally resolved at instance boot from either
`TURN_SHARED_SECRET_SSM_PARAMETER` or `TURN_SHARED_SECRET_SECRET_ID` in
`/etc/cloudsec-rbi/turn.env`. Keep that file limited to parameter names and
non-secret runtime settings when injecting it with user data, SSM State Manager,
or another bootstrap mechanism.

## Packer

```bash
packer init cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/images/turn/turn.pkr.hcl
packer build \
  -var 'region=us-east-1' \
  -var 'environment=prod' \
  -var 'project_name=cloudsec-rbi' \
  cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/images/turn/turn.pkr.hcl
```

Prefer `cloudsec_remote_browser/scripts/rbi-build-amis.sh` for normal builds and
promotion to the SSM parameter consumed by the deployment scripts.
