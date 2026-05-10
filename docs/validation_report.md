# E2E Validation Report — AWS Cloud E-Commerce Platform

**Date:** 2026-05-10
**Repository:** https://github.com/qw486759/aws-ecommerce-platform
**AWS Account:** `<redacted>`
**Region:** us-east-1

---

## Summary

| Phase | Description | Result |
|-------|-------------|--------|
| Phase 1 | Local Docker E2E Testing | ✅ 5/5 tests passed |
| Phase 2 | Terraform Infrastructure | ✅ 47 resources created |
| Phase 3 | ECR Image Push + ECS Deployment | ✅ |
| Phase 4 | CI/CD Pipeline (GitHub Actions) | ✅ 2m 35s, zero errors |
| Phase 5 | Terraform Destroy | ✅ 47 resources destroyed |
| Supplemental 1 | Terraform fmt + validate | ✅ |
| Supplemental 2 | CloudWatch Alarms + SNS | ✅ 9 alarms confirmed |
| Supplemental 3 | ALB Target Health | ✅ all targets healthy |

---

## Phase 1 — Local Docker E2E Testing

**Purpose:** Validate application logic without incurring AWS costs.

**Mechanism:**
- `docker-compose` spins up a full local environment simulating AWS services
- `mysql:8.0` simulates RDS MySQL
- `amazon/dynamodb-local` simulates DynamoDB
- `dynamodb-init` uses a `until` retry loop (not `sleep`) to wait for DynamoDB readiness before creating the table and GSI
- `ecommerce-app:local` runs the FastAPI application

**Commands:**
```powershell
docker build -t ecommerce-app:local .
docker compose up -d
$env:BASE_URL = "http://localhost:8000"
pytest tests/test_api.py -v
```

**Results:**
| Test | Result |
|------|--------|
| test_health | ✅ PASSED |
| test_create_product | ✅ PASSED |
| test_list_products | ✅ PASSED |
| test_create_order | ✅ PASSED |
| test_get_orders | ✅ PASSED |

---

## Phase 2 — Terraform Infrastructure

**Purpose:** Validate IaC correctness and provision all AWS resources.

**Mechanism:**
- `terraform plan` previews all changes without creating any resources
- `terraform apply` provisions infrastructure
- AWS CLI commands verify each resource tier independently

**Commands:**
```powershell
aws ssm put-parameter \
  --name "/ecommerce/db_password" \
  --value "<password>" \
  --type "SecureString" \
  --region us-east-1

terraform init
terraform plan   # 47 to add, 0 to change, 0 to destroy
terraform apply
```

**Verification commands:**
```powershell
aws ecs list-clusters --region us-east-1
aws ecs list-services --cluster ecommerce-cluster --region us-east-1
aws ecs list-services --cluster ecommerce-cluster-staging --region us-east-1
aws ecr describe-repositories --region us-east-1
aws rds describe-db-instances \
  --query "DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus]" \
  --region us-east-1
```

**Results:**
| Resource | Status |
|----------|--------|
| terraform plan | ✅ 47 to add, 0 to change, 0 to destroy |
| terraform apply | ✅ 47 resources created |
| ECS cluster (production) | ✅ ecommerce-cluster |
| ECS cluster (staging) | ✅ ecommerce-cluster-staging |
| ECS service (production) | ✅ ecommerce-service |
| ECS service (staging) | ✅ ecommerce-service-staging |
| ECR repository | ✅ scan_on_push = true |
| RDS MySQL | ✅ available |

---

## Phase 3 — ECR Image Push + ECS Deployment

**Purpose:** Validate Docker image can be pushed to ECR and ECS tasks start successfully.

**Mechanism:**
- Windows PowerShell pipe (`|`) modifies byte encoding when passing tokens to `--password-stdin`, causing ECR to return HTTP 400. Using `cmd /c` preserves the raw byte stream and resolves this. This was the reliable approach used in this Windows PowerShell environment.
- Both `production` and `staging` tags are pushed to match ECS task definition image references.
- ECS does **not** automatically detect a new image with the same tag. `force-new-deployment` is required for the initial manual deployment. In normal CI/CD operation, `amazon-ecs-render-task-definition` registers a new task definition revision on every run, which triggers a rolling update automatically.

**Commands:**
```powershell
# Login (Windows PowerShell — use cmd /c to preserve pipe byte stream)
cmd /c "aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ecr-url>"

# Tag and push
docker tag ecommerce-app:local <ecr-url>/ecommerce-app:production
docker tag ecommerce-app:local <ecr-url>/ecommerce-app:staging
docker push <ecr-url>/ecommerce-app:production
docker push <ecr-url>/ecommerce-app:staging

# Force deploy (initial manual deployment only)
aws ecs update-service \
  --cluster ecommerce-cluster \
  --service ecommerce-service \
  --force-new-deployment \
  --region us-east-1
```

**Results:**
| Item | Result |
|------|--------|
| ECR login | ✅ Login Succeeded |
| production tag push | ✅ 9 layers pushed |
| staging tag push | ✅ layers reused |
| ECS tasks running | ✅ |

---

## Phase 4 — CI/CD Pipeline (GitHub Actions)

**Purpose:** Validate the full automated deployment pipeline from code push to production.

**Mechanism:**
- Push to `main` triggers `deploy-staging.yml`
- `amazon-ecr-login@v2` handles ECR token automatically — no manual login required
- `deploy-staging` job waits for ECS service stability (`wait-for-service-stability: true`)
- `integration-test` job runs pytest against the staging ALB
- `approve-production` job triggers GitHub Environment protection rule — requires manual approval
- `deploy-production` executes only after approval

**Trigger:**
```powershell
git commit --allow-empty -m "ci: trigger CI/CD pipeline for E2E validation"
git push origin main
```

**Pipeline run #21 results:**
| Stage | Result | Duration |
|-------|--------|----------|
| Lint and Validate | ✅ | 14s |
| Build and Push to ECR | ✅ | 23s |
| Deploy to Staging | ✅ | 1m 44s |
| Integration Tests (Staging) | ✅ | 16s |
| Waiting for Production Approval | ✅ | 3s |
| Deploy to Production | ✅ | 1m 39s |
| **Total** | **✅ Success** | **2m 35s** |

---

## Phase 5 — Terraform Destroy

**Purpose:** Validate all resources can be cleanly removed to eliminate idle charges.

**Command:**
```powershell
terraform destroy
```

**Results:**
| Item | Result |
|------|--------|
| terraform destroy | ✅ 47 resources destroyed |
| Billing stopped | ✅ |

**Total demo cost:** ~$0.35 USD (2-hour run at $0.161/hr)

---

## Supplemental 1 — Terraform Format + Validate

**Purpose:** Confirm all Terraform files meet formatting standards and pass static validation.

**Commands:**
```powershell
terraform fmt -check -recursive
terraform validate
```

**Results:**
| Command | Result |
|---------|--------|
| terraform fmt -check -recursive | ✅ No output (all files correctly formatted) |
| terraform validate | ✅ `Success! The configuration is valid.` |

**Note:** `terraform apply` is a stronger signal than `validate` alone — a successful apply confirms both syntax correctness and AWS API acceptance of all resource definitions.

---

## Supplemental 2 — CloudWatch Alarms + SNS

**Purpose:** Confirm the observability layer described in README is fully operational.

**Commands:**
```powershell
aws cloudwatch describe-alarms --region us-east-1 \
  --query "MetricAlarms[*].[AlarmName,StateValue]" --output table
aws sns list-topics --region us-east-1
aws sns list-subscriptions --region us-east-1
```

**CloudWatch Alarms:**
| Alarm | State |
|-------|-------|
| ecommerce-alb-5xx-high | ✅ OK |
| ecommerce-alb-response-time-high | ✅ OK |
| ecommerce-alb-unhealthy-hosts | ✅ OK |
| ecommerce-ecs-cpu-high | ✅ OK |
| ecommerce-ecs-memory-high | ✅ OK |
| ecommerce-ecs-task-count-low | ✅ OK |
| ecommerce-rds-cpu-high | ✅ OK |
| ecommerce-rds-storage-low | ✅ OK |
| ecommerce-rds-connections-high | ✅ OK |
| TargetTracking alarms | ✅ INSUFFICIENT_DATA (expected — no traffic data yet) |

**SNS:**
| Item | Result |
|------|--------|
| Topic `ecommerce-alerts` | ✅ Exists |
| Email subscription | ✅ Confirmed |

**Note:** Two duplicate SNS subscriptions were created due to running `terraform apply` twice. Functionally correct — both subscriptions deliver alerts. Can be resolved by importing the existing subscription into Terraform state before the next `apply`.

---

## Supplemental 3 — ALB Target Health

**Purpose:** Confirm ECS tasks are registered with ALB target groups and passing health checks — the strongest signal that the application is actually serving traffic.

**Commands:**
```powershell
aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[*].[TargetGroupName,TargetGroupArn]" --output table

aws elbv2 describe-target-health \
  --target-group-arn <production-target-group-arn> \
  --region us-east-1 \
  --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]"

aws elbv2 describe-target-health \
  --target-group-arn <staging-target-group-arn> \
  --region us-east-1 \
  --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]"
```

**Results:**
| Environment | Targets | State |
|-------------|---------|-------|
| Production | 2 private IPs | ✅ healthy |
| Staging | 1 private IP | ✅ healthy |

**Note:** Production has 2 healthy targets matching `desired_count = 2`. Staging has 1 matching `desired_count = 1`. Both consistent with Terraform configuration.

---

## Known Limitations

| Item | Description | Impact |
|------|-------------|--------|
| STAGING_ALB_DNS | ALB DNS changes on every `terraform apply`; must update GitHub Secret manually | Low — resolved by adding Route 53 in production |
| SNS duplicate subscriptions | Two subscriptions created from two `terraform apply` runs | Low — both deliver alerts correctly |
| Windows ECR login | PowerShell pipe encoding issue requires `cmd /c` workaround | Low — reliable workaround for this Windows PowerShell environment |
| No Route 53 | Fixed domain not configured; staging URL changes each deployment | Low — intentional for cost reasons in demo |
| CI/CD depends on live infrastructure | After `terraform destroy`, GitHub Actions deployment jobs will fail until infrastructure is recreated | Expected — run `terraform apply` before triggering pipeline |

---

## Re-deployment Checklist

When rebuilding the environment for a future demo:

```powershell
# 1. Apply infrastructure (~15-20 minutes)
terraform apply

# 2. Update STAGING_ALB_DNS GitHub Secret
terraform output staging_alb_dns_name
# Go to: GitHub Settings → Secrets → update STAGING_ALB_DNS

# 3. Trigger CI/CD pipeline
git commit --allow-empty -m "ci: trigger deployment"
git push origin main
```

**Total rebuild time:** ~25 minutes
**Total rebuild cost:** ~$0.35 USD

---

### Optional: If ECR repository already exists outside Terraform state

This situation occurs when ECR was manually created or persisted from a previous run.

```powershell
# Import existing ECR into Terraform state before apply
terraform import aws_ecr_repository.app ecommerce-app
terraform apply
```
