# SWG PrivateLink Consumer

This root is applied in the SWG AWS account and region that owns the SWG
consumer VPC. It creates the interface endpoint that makes the provider-owned
RBI bootstrap private DNS name resolve inside that VPC.

Provider-side state is not enough for DNS resolution. The RBI account creates
the endpoint service and verifies `bootstrap.<rbi-domain>` ownership, but SWG
must still create a consumer interface endpoint with private DNS enabled.

## Current Dev Context

- RBI provider service: `com.amazonaws.vpce.ap-south-1.vpce-svc-0de0480bb25d09fbf`
- RBI private DNS: `bootstrap.dev-rbi.cubex.vyom.umbrella-engineering.com`
- SWG dev pod observed on Kubernetes node region: `us-west-2`

If SWG and RBI are in different regions, deploy a regional RBI provider in the
same region as SWG, or use an AWS PrivateLink cross-region design supported by
the target AWS accounts/tooling. With the current AWS CLI/provider available in
this workspace, no cross-region endpoint creation parameter is exposed.

## Apply

Create a tfvars file in the SWG account with real VPC/subnet values:

```hcl
aws_region            = "us-west-2"
project_name          = "cloudsec-rbi"
environment           = "dev"
name_suffix           = "swg-usw2-dev"
vpc_id                = "vpc-..."
vpc_cidr_blocks       = ["100.105.0.0/16"]
subnet_ids            = ["subnet-...", "subnet-..."]
endpoint_service_name = "com.amazonaws.vpce.ap-south-1.vpce-svc-0de0480bb25d09fbf"
private_dns_enabled   = true
```

Then initialize this root with the SWG account backend and apply it.

Because the provider endpoint service currently requires acceptance, the RBI
provider account must accept the resulting `vpc_endpoint_id` before the private
DNS name becomes usable.
