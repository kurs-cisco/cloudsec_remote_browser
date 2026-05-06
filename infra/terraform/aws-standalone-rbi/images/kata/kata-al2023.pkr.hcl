packer {
  required_version = ">= 1.8.0"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.3.9"
    }
  }
}

variable "region" {
  type        = string
  description = "AWS region where Packer builds and registers the AMI."
}

variable "profile" {
  type        = string
  description = "Optional AWS shared config profile."
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Project name for tags."
  default     = "cloudsec-rbi"
}

variable "environment" {
  type        = string
  description = "Deployment environment for tags and AMI names."
  default     = "dev"
}

variable "eks_version" {
  type        = string
  description = "EKS minor version used by the source AMI name filter."
  default     = "1.31"
}

variable "build_id" {
  type        = string
  description = "Immutable build identifier. Defaults to a UTC timestamp."
  default     = ""
}

variable "ami_name" {
  type        = string
  description = "Optional exact AMI name."
  default     = ""
}

variable "ami_name_prefix" {
  type        = string
  description = "Prefix used when ami_name is not supplied."
  default     = "cloudsec-rbi"
}

variable "source_ami_name_filter" {
  type        = string
  description = "EKS-optimized AL2023 source AMI name filter."
  default     = ""
}

variable "source_ami_owners" {
  type        = list(string)
  description = "Source AMI owners."
  default     = ["amazon"]
}

variable "instance_type" {
  type        = string
  description = "Temporary build instance type. Use bare metal for KVM validation."
  default     = "c5.metal"
}

variable "ssh_username" {
  type        = string
  description = "SSH username for the source AMI."
  default     = "ec2-user"
}

variable "subnet_id" {
  type        = string
  description = "Optional subnet for the Packer build instance."
  default     = ""
}

variable "security_group_id" {
  type        = string
  description = "Optional security group for the Packer build instance."
  default     = ""
}

variable "temporary_security_group_source_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed to SSH to Packer temporary security groups. Do not use 0.0.0.0/0 in guarded accounts."
  default     = []
}

variable "associate_public_ip_address" {
  type        = bool
  description = "Whether Packer should associate a public IP with the build instance."
  default     = true
}

variable "root_device_name" {
  type        = string
  description = "Root block device name."
  default     = "/dev/xvda"
}

variable "root_volume_size_gib" {
  type        = number
  description = "Root EBS volume size."
  default     = 80
}

variable "root_volume_iops" {
  type        = number
  description = "Root gp3 IOPS."
  default     = 6000
}

variable "root_volume_throughput" {
  type        = number
  description = "Root gp3 throughput."
  default     = 500
}

variable "kata_rpm_urls" {
  type        = string
  description = "Optional space-separated Kata RPM URLs."
  default     = ""
}

variable "kata_static_tarball_url" {
  type        = string
  description = "Optional Kata static release tarball URL."
  default     = ""
}

variable "cloud_hypervisor_rpm_url" {
  type        = string
  description = "Optional Cloud Hypervisor RPM URL."
  default     = ""
}

variable "cloud_hypervisor_binary_url" {
  type        = string
  description = "Optional Cloud Hypervisor binary URL."
  default     = ""
}

variable "validate_kvm" {
  type        = bool
  description = "Require /dev/kvm during Packer validation."
  default     = true
}

variable "output_ssm_parameter" {
  type        = string
  description = "SSM parameter name that the wrapper script will promote this AMI to."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Additional AMI tags."
  default     = {}
}

locals {
  build_id               = var.build_id != "" ? var.build_id : formatdate("YYYYMMDDhhmmss", timestamp())
  ami_name               = var.ami_name != "" ? var.ami_name : "${var.ami_name_prefix}-${var.environment}-kata-worker-${local.build_id}"
  source_ami_name_filter = var.source_ami_name_filter != "" ? var.source_ami_name_filter : "amazon-eks-node-al2023-x86_64-standard-${var.eks_version}-v*"

  common_tags = merge(
    var.tags,
    {
      Name        = local.ami_name
      Project     = var.project_name
      Environment = var.environment
      Component   = "standalone-rbi-kata-worker"
      ManagedBy   = "packer"
    },
  )
}

source "amazon-ebs" "kata" {
  ami_description             = "CloudSec standalone RBI AL2023 Kata worker AMI"
  ami_name                    = local.ami_name
  associate_public_ip_address = var.associate_public_ip_address
  instance_type               = var.instance_type
  profile                     = var.profile != "" ? var.profile : null
  region                      = var.region
  security_group_id           = var.security_group_id != "" ? var.security_group_id : null
  ssh_username                = var.ssh_username
  subnet_id                   = var.subnet_id != "" ? var.subnet_id : null
  temporary_security_group_source_cidrs = var.temporary_security_group_source_cidrs

  source_ami_filter {
    filters = {
      architecture        = "x86_64"
      name                = local.source_ami_name_filter
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = var.source_ami_owners
  }

  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = var.root_device_name
    encrypted             = true
    iops                  = var.root_volume_iops
    throughput            = var.root_volume_throughput
    volume_size           = var.root_volume_size_gib
    volume_type           = "gp3"
  }

  run_tags = merge(local.common_tags, {
    Name = "${local.ami_name}-build"
  })

  snapshot_tags = local.common_tags
  tags          = local.common_tags
}

build {
  name    = "kata"
  sources = ["source.amazon-ebs.kata"]

  provisioner "file" {
    source      = "${path.root}/scripts/bootstrap-kata-worker-host.sh"
    destination = "/tmp/bootstrap-kata-worker-host.sh"
  }

  provisioner "shell" {
    execute_command   = "sudo -E env {{ .Vars }} bash '{{ .Path }}'"
    expect_disconnect = true
    pause_after       = "30s"
    skip_clean        = true
    environment_vars = [
      "KATA_RPM_URLS=${var.kata_rpm_urls}",
      "KATA_STATIC_TARBALL_URL=${var.kata_static_tarball_url}",
      "CLOUD_HYPERVISOR_RPM_URL=${var.cloud_hypervisor_rpm_url}",
      "CLOUD_HYPERVISOR_BINARY_URL=${var.cloud_hypervisor_binary_url}",
      "KATA_VALIDATE_KVM=${var.validate_kvm}",
    ]
    scripts = [
      "${path.root}/scripts/install-kata-al2023.sh",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -E env {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "KATA_VALIDATE_KVM=${var.validate_kvm}",
    ]
    scripts = [
      "${path.root}/scripts/validate-kata.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/../artifacts/kata-packer-manifest.json"
    strip_path = true
    custom_data = {
      component     = "kata-worker"
      ssm_parameter = var.output_ssm_parameter
    }
  }
}
