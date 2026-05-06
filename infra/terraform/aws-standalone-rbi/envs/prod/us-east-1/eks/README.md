# Standalone RBI EKS Root

This root owns AWS infrastructure only: the EKS cluster, the standard managed node
group for RBI control-plane workloads, and the dedicated bare-metal Kata managed
node group for RBI workers.

Apply this root before `../apps`.

```bash
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Keep the Kubernetes resources in the apps root as a separate state so cluster
replacement and app rollout remain disjoint.
