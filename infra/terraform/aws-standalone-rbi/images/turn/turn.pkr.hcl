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
  description = "Amazon Linux 2023 source AMI name filter."
  default     = "al2023-ami-2023.*-x86_64"
}

variable "source_ami_owners" {
  type        = list(string)
  description = "Source AMI owners."
  default     = ["amazon"]
}

variable "instance_type" {
  type        = string
  description = "Temporary build instance type."
  default     = "t3.small"
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
  default     = 20
}

variable "coturn_image" {
  type        = string
  description = "coturn container image to pre-pull and run."
  default     = "coturn/coturn:4.6"
}

variable "turn_default_realm" {
  type        = string
  description = "Non-secret default realm written to the example runtime env file."
  default     = "cloudsec-rbi.local"
}

variable "turn_port" {
  type        = number
  description = "TURN UDP/TCP listener port."
  default     = 3478
}

variable "turn_tls_port" {
  type        = number
  description = "Optional TURN-over-TLS listener port when cert and key paths are configured."
  default     = 443
}

variable "turn_min_port" {
  type        = number
  description = "Minimum UDP relay port."
  default     = 49152
}

variable "turn_max_port" {
  type        = number
  description = "Maximum UDP relay port."
  default     = 65535
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
  build_id = var.build_id != "" ? var.build_id : formatdate("YYYYMMDDhhmmss", timestamp())
  ami_name = var.ami_name != "" ? var.ami_name : "${var.ami_name_prefix}-${var.environment}-turn-${local.build_id}"

  common_tags = merge(
    var.tags,
    {
      Name        = local.ami_name
      Project     = var.project_name
      Environment = var.environment
      Component   = "standalone-rbi-turn"
      ManagedBy   = "packer"
    },
  )
}

source "amazon-ebs" "turn" {
  ami_description             = "CloudSec standalone RBI TURN AMI"
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
      name                = var.source_ami_name_filter
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
  name    = "turn"
  sources = ["source.amazon-ebs.turn"]

  provisioner "file" {
    source      = "${path.root}/files/cloudsec-rbi-turn.service"
    destination = "/tmp/cloudsec-rbi-turn.service"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/start-coturn.sh"
    destination = "/tmp/start-coturn.sh"
  }

  provisioner "shell" {
    execute_command   = "sudo -E env {{ .Vars }} bash '{{ .Path }}'"
    expect_disconnect = true
    pause_after       = "30s"
    skip_clean        = true
    environment_vars = [
      "COTURN_IMAGE=${var.coturn_image}",
      "TURN_DEFAULT_REALM=${var.turn_default_realm}",
      "TURN_PORT=${var.turn_port}",
      "TURN_TLS_PORT=${var.turn_tls_port}",
      "TURN_MIN_PORT=${var.turn_min_port}",
      "TURN_MAX_PORT=${var.turn_max_port}",
    ]
    scripts = [
      "${path.root}/scripts/install-turn.sh",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -E env {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "COTURN_IMAGE=${var.coturn_image}",
    ]
    scripts = [
      "${path.root}/scripts/validate-turn.sh",
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/../artifacts/turn-packer-manifest.json"
    strip_path = true
    custom_data = {
      component     = "turn"
      ssm_parameter = var.output_ssm_parameter
    }
  }
}
