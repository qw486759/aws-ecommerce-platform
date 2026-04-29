# Architecture Decision Records

This document records the background, options, trade-offs, and conclusions
behind each key architectural decision. The goal is not to describe what was
built, but to explain why it was built that way.

---

## ADR-001: Migrate Compute Layer from EC2 to ECS Fargate

**Status**: Adopted

### Background

The original architecture used two EC2 t3.micro instances behind an ALB.
Deployment required SSH access to run git pull and restart the process manually,
which could not be integrated into a CI/CD pipeline. OS patching and AMI
management also added ongoing operational overhead.

### Options Evaluated

| Option | Pros | Cons |
|--------|------|------|
| EC2 + CodeDeploy | Minimal changes | Still requires OS and AMI management |
| ECS EC2 launch type | ~20% cheaper than Fargate | Still requires managing underlying EC2 |
| ECS Fargate | No server management, clean ECR and GitHub Actions integration | Slightly higher cost |
| EKS | Maximum flexibility | Over-engineering for this scale |

### Decision

Adopted ECS Fargate. The core requirement is push code and deploy automatically.
Fargate eliminates OS management overhead and allows the CI/CD pipeline to trigger
rolling deployments directly via ecs update-service without additional tooling.

---

## ADR-002: CI/CD Pipeline Environment Strategy

**Status**: Adopted (single-environment by default, dual-environment optional)

### Strategy A: Single Environment, Direct to Production (deploy.yml, default)

PR -> CI (pytest + terraform plan) -> merge to main -> deploy production

Suitable for: small teams, rapid iteration, high automated test coverage

### Strategy B: Dual Environment with Approval Gate (deploy-staging.yml, optional)

PR -> CI -> merge -> auto deploy staging -> manual verification
  -> GitHub approval gate -> deploy production

Suitable for: production environments with real users, payment flows,
or compliance requirements

### Decision

Both workflows are maintained. Strategy A is the default.
Strategy B exists as a separate workflow file activated by creating a staging
branch and configuring GitHub Environment protection rules.
No workflow rewrite is needed to upgrade.

### Cost Comparison

| Architecture | Daily Cost | Use Case |
|-------------|-----------|----------|
| Single environment (production only) | ~$2.5/day | Personal projects, early-stage startups |
| Dual environment (staging + production) | ~$3.8/day | Growth-stage companies with compliance needs |
| Difference | +$1.3/day | Cost of one incident typically far exceeds this |

---

## ADR-003: Database Selection

**Status**: Adopted

### Decision

Products -> RDS MySQL Multi-AZ
  Relational data with ACID transactions ensures inventory consistency.
  Multi-AZ provides automatic failover with ~99.95% availability SLA.

Orders -> DynamoDB on-demand
  Flexible schema accommodates variable item counts per order.
  On-demand billing means near-zero cost at low traffic.
  GSI enables efficient queries by user_id.

### Why Not All RDS

Order writes are bursty during flash sales. DynamoDB on-demand handles
sudden spikes without pre-provisioning instance size or read replicas.

### Why Not All DynamoDB

Product queries require complex filtering such as WHERE category = X AND price < Y.
Implementing this in DynamoDB requires full scans or complex GSI design,
which is less intuitive and harder to cost-control than SQL.

---

## ADR-004: Secrets Management

**Status**: Adopted

| Secret Type | Storage | Reason |
|-------------|---------|--------|
| DB password | AWS SSM Parameter Store SecureString | Encrypted at rest, IAM-controlled access |
| AWS credentials for CI/CD | GitHub Secrets | Native GitHub Actions support, never logged |
| terraform.tfvars | gitignored, maintained locally | Prevents state file leakage |

The ECS Task Role grants only ssm:GetParameter on the /ecommerce/* namespace,
following the principle of least privilege.

---

## Upgrade Path

| Current (demo) | Future (production-ready) |
|----------------|--------------------------|
| Single-environment deploy.yml | Enable dual-environment deploy-staging.yml |
| ECS Fargate 2 tasks fixed | Auto Scaling 2-10 tasks based on CPU |
| RDS t3.micro | RDS t3.small + read replica |
| SSM Parameter Store | AWS Secrets Manager with auto-rotation |
| HTTP only | HTTPS + ACM certificate + Route 53 |
