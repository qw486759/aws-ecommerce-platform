# ─────────────────────────────────────────────────────────────────────────────
# main.tf — Root Terraform configuration
#
# Declares the required AWS provider and imports the existing VPC / subnets
# that were created manually via the AWS Console (Phase 2).
# All other resources reference these data sources so nothing is recreated.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Look up the existing VPC by Name tag instead of hard-coding its ID.
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["ecommerce-vpc-vpc"]
  }
}

# Fetch all public subnets inside the VPC (used by the ALB and NAT Gateway).
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*public*"]
  }
}

# Fetch all private subnets inside the VPC (used by ECS tasks and RDS).
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}
