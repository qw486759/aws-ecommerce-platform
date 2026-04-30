# Demo Walkthrough

## Overview

This document walks through the live demo of the AWS Cloud E-Commerce Platform. The intent is to show not just *that* things work, but *why* each component exists and what failure behavior looks like when something goes wrong.

The demo runs against the production-equivalent environment (single-env deploy.yml, ECS Fargate, RDS Multi-AZ). If you want to observe the staging approval gate flow, see the note at the end.

---

## Prerequisites

Before starting, confirm the following are up:

```bash
# Check ECS service is stable
aws ecs describe-services \
  --cluster ecommerce-cluster \
  --services ecommerce-service \
  --query "services[0].{running:runningCount,desired:desiredCount,status:status}"

# Confirm both ALB targets are healthy
aws elbv2 describe-target-health \
  --target-group-arn <tg-arn> \
  --query "TargetHealthDescriptions[*].{IP:Target.Id,Status:TargetHealth.State}"
```

Expected: 2 running tasks, both targets showing `healthy`.

If either target is unhealthy at demo start, don't proceed — ECS may still be mid-deployment from a recent push.

---

## Step 1: Health Check

Start here. This verifies the entire path: internet → ALB → ECS Fargate → application.

```bash
curl http://<ALB-DNS>/health
```

Expected response:
```json
{"status": "healthy"}
```

**Why this matters:** The ALB only routes to tasks that pass this endpoint. If `/health` is working, it means the container started cleanly, environment variables were injected (including DB_PASSWORD from SSM), and the application process is alive.

---

## Step 2: Product Catalog (RDS Read Path)

```bash
curl http://<ALB-DNS>/products
```

This hits RDS MySQL. The products table lives in the relational store because products have structured schema and benefit from SQL queries (filtering, joins eventually).

If this returns 500, the most common causes in order of likelihood:
1. DB_HOST env var not set or wrong in task definition
2. RDS security group blocking the ECS task's subnet
3. Products table doesn't exist (would have been created by the one-time init task)

The security group issue is subtle — I actually hit it during initial deployment. One of the two Fargate tasks was in a different subnet than what the RDS SG originally allowed. Half the requests were failing. The fix was adding the ECS tasks SG as an allowed source in the RDS ingress rule. Documented in ADR-005.

---

## Step 3: Create an Order (DynamoDB Write Path)

```bash
curl -X POST http://<ALB-DNS>/orders \
  -H "Content-Type: application/json" \
  -d '{"user_id": "demo-user", "product_id": "prod-001", "quantity": 2}'
```

Expected: 201 with an `order_id` in the response.

Orders go to DynamoDB instead of RDS. The reasoning: orders are written once and read by `order_id` or `user_id` — a pure key-value access pattern. No joins needed. DynamoDB PAY_PER_REQUEST also means the demo environment costs nothing when idle, vs. provisioned RDS capacity. See ADR-002 for the full decision rationale.

---

## Step 4: Retrieve Orders by User

```bash
curl http://<ALB-DNS>/orders?user_id=demo-user
```

This exercises the GSI on `user_id`. Without the GSI, this would be a full table scan — not viable at scale. The GSI allows DynamoDB to answer "give me all orders for user X" efficiently.

---

## Step 5: Simulate a CI/CD Deployment

Push a minor change to `main` (e.g., update a comment in `main.py`) and watch the pipeline:

```
GitHub Actions → pytest → docker build → ECR push → ECS rolling deploy
```

The interesting part to observe: during the rolling deploy, ECS starts new tasks before stopping old ones (`minimum_healthy_percent=50`, `maximum_percent=200`). With 2 desired tasks, it temporarily runs 4. New tasks must pass ALB health checks before old ones are deregistered.

While the deployment is in progress, keep hitting `/health` in a loop:

```bash
watch -n 1 curl -s http://<ALB-DNS>/health
```

You should see uninterrupted 200s throughout. That's zero-downtime deployment.

If the new image has a bug and health checks fail, ECS stops the rollout and leaves the old tasks running. GitHub Actions marks the workflow as failed. The old version stays live. This is the behavior demonstrated in the failure scenarios doc.

---

## Step 6 (Optional): Staging Approval Gate

If demoing the dual-environment workflow:

1. Push to `staging` branch instead of `main`
2. Watch the pipeline auto-deploy to the staging ECS service
3. Verify staging looks good: `curl http://<staging-ALB-DNS>/health`
4. Go to GitHub → Actions → the pending workflow → click Approve
5. Production deployment kicks off automatically

The approval gate is implemented via GitHub Environments. The `production` environment has a required reviewer configured. One line in the workflow YAML — `environment: production` — is what triggers the pause. Worth showing this to anyone who asks about governance controls.

---

## Tear Down

```bash
terraform destroy
```

All resources are managed by Terraform. One command removes everything. The only thing not managed by Terraform is the VPC itself (intentionally — shared infrastructure) and the SSM parameter for DB_PASSWORD (set manually once).

After destroy, confirm no lingering costs:
- ECS service and tasks: gone
- RDS instance: gone (this is the big one — ~$0.017/hour)
- NAT Gateway: gone (~$0.045/hour)
- ALB: gone
- DynamoDB: PAY_PER_REQUEST, zero cost when no traffic anyway

ECR images persist (minimal cost), and the SSM parameter persists. Both are fine to leave.

---

## Notes on the Dual-Environment Cost

Single-env daily cost: ~$2.50  
Dual-env (with staging always running) daily cost: ~$3.80

The delta is $1.30/day — roughly one ECS Fargate task running in staging 24/7. For a demo, you'd only bring up staging when needed and tear it down after. The staging workflow is in the repo as an option, not a default, specifically for this reason.
