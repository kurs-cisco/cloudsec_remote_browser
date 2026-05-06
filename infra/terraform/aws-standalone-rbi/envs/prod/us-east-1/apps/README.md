# Standalone RBI Apps Root

This root owns Kubernetes resources only. It connects to the EKS cluster by name,
then applies the `kata-clh` RuntimeClass, RBI namespaces, ServiceAccount,
NetworkPolicy, warm-pool Deployment template, and suspended session Job template.
When supplied with target group ARNs from the sibling network root, it also emits
AWS Load Balancer Controller `TargetGroupBinding` manifests for RBI control-plane
Services.

Apply this root after `../eks`.

```bash
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Secrets are intentionally not stored in Terraform state. The optional
`secret_provider_classes` input can create deterministic Secrets Store CSI
`SecretProviderClass` manifests that reference external secret names or ARNs, but
secret values must still be populated and rotated outside Terraform.
