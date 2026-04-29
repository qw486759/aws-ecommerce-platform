# ─────────────────────────────────────────────────────────────────────────────
# compute.tf — EC2 instances, ALB, NAT Gateway, and IAM roles
#
# Traffic flow:
#   Internet → ALB (public subnets) → EC2 x2 (private subnets) → RDS / DynamoDB
#
# NAT Gateway allows EC2 instances in private subnets to reach the internet
# (e.g. to install packages via pip/yum) without exposing them directly.
# ─────────────────────────────────────────────────────────────────────────────

# ── IAM Role ─────────────────────────────────────────────────────────────────
# Grants EC2 instances the ability to:
#   1. Use SSM Session Manager (console-based shell access without SSH keys)
#   2. Read/write DynamoDB tables

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "dynamodb" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# Instance profile is the container that attaches the IAM role to an EC2 instance
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
# Elastic IP for the NAT Gateway (static public IP)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name    = "${var.project_name}-nat-eip"
    Project = var.project_name
  }
}

# NAT Gateway sits in a public subnet and provides outbound internet access
# to resources in the private subnets (EC2 instances).
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = tolist(data.aws_subnets.public.ids)[0] # place in first public subnet

  tags = {
    Name    = "${var.project_name}-nat-gw"
    Project = var.project_name
  }
}

# Add a default route (0.0.0.0/0 → NAT Gateway) to every private route table.
# for_each handles the case where the VPC wizard created one route table per AZ.
resource "aws_route" "private_nat" {
  for_each               = toset(tolist(data.aws_route_tables.private.ids))
  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# Data source: look up all private route tables by VPC and Name tag
data "aws_route_tables" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

# ── EC2 Bootstrap Script (user_data) ─────────────────────────────────────────
# Runs once on first boot. Steps:
#   1. Install Python 3 and pip packages.
#   2. Write environment variables to /etc/profile.d/app.sh.
#   3. Copy app/main.py to /app/main.py on the instance.
#   4. Poll RDS until it accepts connections (handles the case where RDS is
#      still initialising when EC2 boots).
#   5. Create the `products` MySQL table if it does not exist.
#   6. Register and start a systemd service so FastAPI survives reboots.

locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e
    yum update -y
    yum install -y python3 python3-pip git

    pip3 install fastapi uvicorn pymysql boto3 cryptography pydantic

    # Write env vars to a profile script (sourced by interactive shells)
    cat > /etc/profile.d/app.sh << 'ENVEOF'
export DB_HOST=${aws_db_instance.mysql.address}
export DB_PORT=3306
export DB_USER=admin
export DB_PASSWORD=${var.db_password}
export DB_NAME=ecommerce
export AWS_REGION=us-east-1
export DYNAMO_TABLE=ecommerce-orders
ENVEOF
    chmod +x /etc/profile.d/app.sh
    source /etc/profile.d/app.sh

    # Deploy application code
    mkdir -p /app
    cat > /app/main.py << 'PYEOF'
${file("app/main.py")}
PYEOF

    # Wait for RDS to become available (retry up to 20 times, 15 s apart)
    echo "Waiting for RDS to be ready..."
    for i in {1..20}; do
      python3 -c "
import pymysql, os
try:
    conn = pymysql.connect(
        host='${aws_db_instance.mysql.address}',
        port=3306,
        user='admin',
        password='${var.db_password}',
        database='ecommerce'
    )
    conn.close()
    print('RDS is ready!')
    exit(0)
except Exception as e:
    print(f'Attempt $i: {e}')
    exit(1)
" && break || sleep 15
    done

    # Create the products table (idempotent — safe to run multiple times)
    python3 << 'SQLEOF'
import pymysql, os
conn = pymysql.connect(
    host='${aws_db_instance.mysql.address}',
    port=3306,
    user='admin',
    password='${var.db_password}',
    database='ecommerce'
)
with conn.cursor() as cur:
    cur.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            name        VARCHAR(255)   NOT NULL,
            description TEXT,
            price       DECIMAL(10,2)  NOT NULL,
            stock       INT            DEFAULT 0
        )
    """)
conn.commit()
conn.close()
print("Table created successfully!")
SQLEOF

    # Register FastAPI as a systemd service so it restarts on reboot/crash.
    # Environment variables are injected directly to avoid shell-sourcing issues.
    cat > /etc/systemd/system/fastapi.service << SVCEOF
[Unit]
Description=FastAPI E-Commerce App
After=network.target

[Service]
Environment="DB_HOST=${aws_db_instance.mysql.address}"
Environment="DB_PORT=3306"
Environment="DB_USER=admin"
Environment="DB_PASSWORD=${var.db_password}"
Environment="DB_NAME=ecommerce"
Environment="AWS_REGION=us-east-1"
Environment="DYNAMO_TABLE=ecommerce-orders"
ExecStart=/usr/local/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --app-dir /app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable fastapi
    systemctl start fastapi
    echo "FastAPI started successfully!"
  EOF
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────
# Latest Amazon Linux 2 AMI (automatically stays up to date)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Two EC2 instances spread across both private subnets (one per AZ)
resource "aws_instance" "app" {
  count                       = 2
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = tolist(data.aws_subnets.private.ids)[count.index]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  key_name                    = "ecommerce-key"
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true  # force replacement when user_data changes
  user_data                   = local.user_data

  tags = {
    Name    = "${var.project_name}-app-${count.index + 1}"
    Project = var.project_name
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────
# Internet-facing ALB distributes requests across both EC2 instances.
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids # spans both public subnets

  tags = {
    Name    = "${var.project_name}-alb"
    Project = var.project_name
  }
}

# Target group points to port 8000 (uvicorn) on each EC2 instance.
# Health check hits /health every 30 s; 2 successes = healthy, 3 failures = unhealthy.
resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

# Register each EC2 instance with the target group
resource "aws_lb_target_group_attachment" "app" {
  count            = 2
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
  port             = 8000
}

# HTTP listener on port 80 — forwards all requests to the target group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
