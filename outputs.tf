# ─────────────────────────────────────────────────────────────────────────────
# outputs.tf — Terraform output values
#
# These are printed after every `terraform apply` so you can quickly find
# the key identifiers without opening the AWS Console.
# ─────────────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the existing VPC"
  value       = data.aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (ALB, NAT Gateway)"
  value       = data.aws_subnets.public.ids
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets (EC2, RDS)"
  value       = data.aws_subnets.private.ids
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB orders table"
  value       = aws_dynamodb_table.orders.name
}

output "alb_sg_id" {
  description = "Security Group ID attached to the Application Load Balancer"
  value       = aws_security_group.alb.id
}

output "ec2_sg_id" {
  description = "Security Group ID attached to the EC2 application instances"
  value       = aws_security_group.ec2.id
}

output "aurora_sg_id" {
  description = "Security Group ID attached to the RDS instance"
  value       = aws_security_group.aurora.id
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB — use this as your API base URL"
  value       = aws_lb.main.dns_name
}

output "db_endpoint" {
  description = "RDS MySQL connection endpoint (host:port)"
  value       = aws_db_instance.mysql.endpoint
}
