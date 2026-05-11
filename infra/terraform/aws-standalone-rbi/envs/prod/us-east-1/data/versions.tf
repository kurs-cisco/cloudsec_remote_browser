terraform {
  required_version = ">= 1.5.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.provider_tags
  }
}

provider "aws" {
  alias   = "swg_credentials"
  region  = var.swg_credential_secret_region
  profile = var.swg_credential_secret_aws_profile != "" ? var.swg_credential_secret_aws_profile : null

  default_tags {
    tags = local.provider_tags
  }
}
