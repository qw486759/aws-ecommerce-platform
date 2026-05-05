output "alb_dns_name" {
  description = "Production ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "staging_alb_dns_name" {
  description = "Staging ALB DNS name"
  value       = aws_lb.staging.dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "Production ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_staging_name" {
  description = "Staging ECS cluster name"
  value       = aws_ecs_cluster.staging.name
}
