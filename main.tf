terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "aws" {
  region = var.region
}

# クロスリージョンレプリケーション先（大阪）
provider "aws" {
  alias  = "dest"
  region = var.dest_region
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  src_bucket  = "${var.name_prefix}-src-${random_id.suffix.hex}"
  dest_bucket = "${var.name_prefix}-dst-${random_id.suffix.hex}"

  tags = {
    Project = "SOA03-07DAY"
    Purpose = "s3-multipart-crr"
  }
}
