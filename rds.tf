# ─────────────────────────────────────────────────────────────────────────────
# rds.tf — Relational database (RDS MySQL)
#
# Production note: this demo uses RDS MySQL instead of Aurora MySQL because
# Aurora requires a non-free-tier account. The architecture and Terraform
# patterns are identical — swap aws_db_instance for aws_rds_cluster to
# upgrade to Aurora with Multi-AZ in a production environment.
#
# Key design decisions:
#   - db.t3.micro keeps costs minimal for demo purposes.
#   - multi_az = true deploys a standby replica in a second AZ for high
#     availability (automatic failover if the primary fails).
#   - publicly_accessible = false ensures the DB is only reachable from
#     inside the VPC (via the ECS tasks security group).
#   - skip_final_snapshot = true avoids leaving a paid snapshot after destroy.
# ─────────────────────────────────────────────────────────────────────────────

# Subnet group tells RDS which private subnets it may place instances in
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = data.aws_subnets.private.ids

  tags = {
    Name    = "${var.project_name}-db-subnet-group"
    Project = var.project_name
  }
}

# RDS MySQL instance — equivalent to Aurora MySQL for demo purposes
resource "aws_db_instance" "mysql" {
  identifier        = "${var.project_name}-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro" # smallest available class
  allocated_storage = 20            # GiB; minimum allowed
  storage_type      = "gp2"

  db_name  = "ecommerce"
  username = "admin"
  password = var.db_password # injected from terraform.tfvars (git-ignored)

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = true  # standby replica in a second AZ for HA
  publicly_accessible = false # no direct internet access — private subnet only
  skip_final_snapshot = true  # do not create a snapshot on terraform destroy
  deletion_protection = false # allow destroy without manual intervention

  tags = {
    Name    = "${var.project_name}-mysql"
    Project = var.project_name
  }
}
