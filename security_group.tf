# ─────────────────────────────────────────────────────────────────────────────
# security_groups.tf — Network access control (least-privilege design)
#
# Three-tier security model:
#   Internet → ALB SG (port 80 open) → EC2 SG (port 8000, ALB only)
#                                     → Aurora SG (port 3306, EC2 only)
#
# Each tier only accepts traffic from the tier directly above it, so the
# database is never reachable from the public internet.
# ─────────────────────────────────────────────────────────────────────────────

# ALB Security Group — accepts inbound HTTP from anywhere on the internet
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound so the ALB can forward requests to EC2 targets
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-alb-sg"
    Project = var.project_name
  }
}

# EC2 Security Group — only accepts traffic that originates from the ALB
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = data.aws_vpc.main.id

  # FastAPI listens on 8000; source is restricted to the ALB security group
  ingress {
    description     = "HTTP from ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # SSH access for emergency manual debugging (consider restricting to a bastion IP in production)
  ingress {
    description = "SSH for management"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound so EC2 can reach RDS, DynamoDB, and the internet (via NAT)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ec2-sg"
    Project = var.project_name
  }
}

# Aurora/RDS Security Group — only accepts MySQL connections from EC2 instances
resource "aws_security_group" "aurora" {
  name        = "${var.project_name}-aurora-sg"
  description = "Security group for Aurora cluster"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "MySQL from EC2 only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-aurora-sg"
    Project = var.project_name
  }
}
