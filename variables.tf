# ─────────────────────────────────────────────────────────────────────────────
# variables.tf — Input variable declarations
#
# Actual values are supplied via terraform.tfvars (git-ignored).
# The db_password variable is marked sensitive so Terraform never prints it
# in plan/apply output.
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where all resources will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to every resource name for easy identification"
  type        = string
  default     = "ecommerce"
}

variable "db_password" {
  description = "Master password for the RDS MySQL instance"
  type        = string
  sensitive   = true # prevents the value from appearing in Terraform output
}
