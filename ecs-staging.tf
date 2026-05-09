resource "aws_cloudwatch_log_group" "ecs_staging" {
  name              = "/ecs/ecommerce-app-staging"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "staging" {
  name = "ecommerce-cluster-staging"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "ecommerce-cluster-staging", Environment = "staging" }
}

resource "aws_ecs_task_definition" "app_staging" {
  family                   = "ecommerce-task-staging"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "ecommerce-app"
    image     = "${aws_ecr_repository.app.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]

    environment = [
      { name = "AWS_REGION", value = var.aws_region },
      { name = "DYNAMODB_TABLE", value = aws_dynamodb_table.orders.name },
      { name = "ENVIRONMENT", value = "staging" },
      { name = "DB_HOST", value = aws_db_instance.mysql.address },
      { name = "DB_PORT", value = "3306" },
      { name = "DB_NAME", value = "ecommerce" },
      { name = "DB_USER", value = "admin" }
    ]

    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ecommerce/db_password"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_staging.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = { Name = "ecommerce-task-staging", Environment = "staging" }
}

resource "aws_security_group" "alb_staging" {
  name        = "ecommerce-alb-staging-sg"
  description = "Staging ALB security group"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecommerce-alb-staging-sg", Environment = "staging" }
}

resource "aws_security_group" "ecs_tasks_staging" {
  name        = "ecommerce-ecs-tasks-staging-sg"
  description = "Allow traffic from staging ALB to staging ECS tasks"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "App port from staging ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_staging.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecommerce-ecs-tasks-staging-sg", Environment = "staging" }
}

resource "aws_lb" "staging" {
  name               = "ecommerce-alb-staging"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_staging.id]
  subnets            = data.aws_subnets.public.ids

  tags = { Name = "ecommerce-alb-staging", Environment = "staging" }
}

resource "aws_lb_target_group" "app_staging" {
  name        = "ecommerce-tg-staging"
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

  tags = { Name = "ecommerce-tg-staging", Environment = "staging" }
}

resource "aws_lb_listener" "http_staging" {
  load_balancer_arn = aws_lb.staging.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_staging.arn
  }
}

resource "aws_ecs_service" "app_staging" {
  name            = "ecommerce-service-staging"
  cluster         = aws_ecs_cluster.staging.id
  task_definition = aws_ecs_task_definition.app_staging.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.ecs_tasks_staging.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_staging.arn
    container_name   = "ecommerce-app"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.http_staging]

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = { Name = "ecommerce-service-staging", Environment = "staging" }
}
