resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "ecommerce-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.aws_subnets.public.ids[0]
  tags          = { Name = "ecommerce-nat-gw" }
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "ecommerce-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(data.aws_subnets.private.ids)
  subnet_id      = data.aws_subnets.private.ids[count.index]
  route_table_id = aws_route_table.private.id
}

resource "aws_lb" "main" {
  name               = "ecommerce-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids

  tags = { Name = "ecommerce-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "ecommerce-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = { Name = "ecommerce-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ── Staging ALB ───────────────────────────────────────────────────────────────
# Separate ALB isolates staging traffic from production.
# GitHub Actions deploys to staging first, runs integration tests against
# this ALB's DNS, then promotes to production.
resource "aws_lb" "staging" {
  name               = "ecommerce-staging-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids

  tags = { Name = "ecommerce-staging-alb" }
}

resource "aws_lb_target_group" "staging" {
  name        = "ecommerce-staging-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = { Name = "ecommerce-staging-tg" }
}

resource "aws_lb_listener" "http_staging" {
  load_balancer_arn = aws_lb.staging.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staging.arn
  }
}