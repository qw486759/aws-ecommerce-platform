# Architecture Decision Records

This page is the index for architecture decisions in the AWS Cloud E-Commerce Platform. Each ADR documents the context, options considered, decision, trade-offs, and consequences behind a key architecture choice.

| ADR | Decision | Summary |
|-----|----------|---------|
| [ADR-001](adr/adr-001-compute-ecs-fargate-vs-ec2.md) | ECS Fargate vs EC2 | Use ECS Fargate to reduce OS management, support containerized deployment, and integrate cleanly with ECR and GitHub Actions. |
| [ADR-002](adr/adr-002-database-rds-vs-dynamodb.md) | RDS MySQL and DynamoDB | Use RDS MySQL for relational product data and DynamoDB for write-heavy order data with flexible access patterns. |
| [ADR-003](adr/adr-003-cicd-single-vs-dual-environment.md) | CI/CD environment strategy | Keep single-environment deployment as the default and provide a dual-environment workflow with approval gate as an upgrade path. |
| [ADR-004](adr/adr-004-secrets-ssm-parameter-store.md) | Secrets management | Use SSM Parameter Store SecureString to inject database credentials into ECS tasks without hardcoding secrets. |
| [ADR-005](adr/adr-005-network-public-private-subnets.md) | Network isolation | Use public subnets for ALB/NAT and private subnets for ECS tasks and databases to reduce public exposure. |

## Related Documents

- [Demo Walkthrough](demo-walkthrough.md)
- [Failure Scenarios](failure-scenarios.md)
- [Production Readiness](production-readiness.md)
- [Environment Strategy](environments.md)