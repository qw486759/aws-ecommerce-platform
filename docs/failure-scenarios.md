# Failure Scenarios

This document covers the failure behaviors worth understanding (and demonstrating) for this architecture. The goal isn't just "what breaks" — it's "what happens automatically, what requires intervention, and how do you know which situation you're in."

---

## Scenario 1: One ECS Task Becomes Unhealthy

**What triggers this:**
- Application process crashes (unhandled exception, OOM)
- Container exits with non-zero status
- ALB health checks to `/health` start failing consistently

**Expected behavior:**

1. ALB detects the unhealthy target (after 3 consecutive failed health checks, default threshold). Stops routing traffic to that task. Requests go entirely to the remaining healthy task.
2. ECS service controller detects the task count is below `desired_count = 2`. Starts a replacement task.
3. New task goes through the SSM secret fetch → container startup → ALB health check sequence.
4. Once healthy, ALB resumes routing to both tasks.

Throughout this sequence, the application stays available. The single remaining task handles all traffic.

**Validation:**

```bash
# Stop one task manually
aws ecs stop-task \
  --cluster ecommerce-cluster \
  --task <task-arn> \
  --reason "failure scenario test"

# Watch ALB target health
watch -n 5 aws elbv2 describe-target-health \
  --target-group-arn <tg-arn> \
  --query "TargetHealthDescriptions[*].{IP:Target.Id,Status:TargetHealth.State}"

# Confirm application is still responding
curl http://<ALB-DNS>/health
curl http://<ALB-DNS>/products
```

Expected: one target transitions to `unused` or `draining`, then disappears. A new target IP appears and eventually transitions to `healthy`. `/health` and `/products` return 200 throughout.

**What this doesn't test:** sustained load on a single task. If the baseline traffic is near the capacity of one task, this failure scenario would cause degraded performance (higher latency, possible timeouts) rather than complete unavailability. The current task sizing (0.25 vCPU, 512MB) is comfortable for demo traffic but wouldn't handle production load on a single task without degradation.

---

## Scenario 2: New Deployment Fails Health Checks

**What triggers this:**
- Broken application code pushed to `main`
- Dependency version conflict in the new image
- Environment variable mismatch (new code expects a variable that isn't in the task definition)
- Container starts but `/health` endpoint throws an exception

**Expected behavior:**

ECS rolling deployment behavior (`minimum_healthy_percent = 50`, `maximum_percent = 200` with 2 desired tasks):

1. ECS starts 2 new tasks. Total running: 4 (2 old, 2 new).
2. New tasks are registered with the ALB target group.
3. ALB health checks to the new tasks start failing.
4. After the failure threshold is reached, ECS halts the rollout. The 2 new tasks are stopped.
5. The 2 original (healthy) tasks remain running and continue serving traffic.
6. GitHub Actions marks the deployment workflow as failed (`wait-for-service-stability: true`).

**Validation:**

```bash
# In a test branch, intentionally break the health endpoint:
# main.py — change /health to return 500
@app.get("/health")
async def health():
    raise HTTPException(status_code=500, detail="intentional failure")

# Push to main (or a branch connected to the pipeline)
git push origin main

# Watch the deployment
aws ecs describe-services \
  --cluster ecommerce-cluster \
  --services ecommerce-service \
  --query "services[0].deployments"

# GitHub Actions will show a failed workflow
# Old tasks continue to serve traffic
curl http://<ALB-DNS>/health  # Still returns 200 from old tasks
```

**What to look for in the `deployments` output:**

Two deployment entries: one `PRIMARY` (the new, failing deployment) and one `ACTIVE` (the old, healthy one). As the rollout halts, the PRIMARY deployment's `runningCount` stays at 0 and eventually the deployment is rolled back.

**Real example from initial setup:**

During the ECS migration, the task definition's health check used `curl -f http://localhost:8000/health`, but the `python:3.11-slim` base image doesn't include curl. Every new task failed health checks immediately after starting — not because the application was broken, but because the health check command itself didn't exist. The fix was removing the container-level health check entirely and relying on the ALB health check. This is actually the recommended pattern for ECS + ALB anyway.

---

## Scenario 3: RDS Primary Fails Over

**What triggers this:**
- AWS-initiated failover (planned maintenance, AZ issue)
- Manually triggered failover (for testing)
- Underlying hardware failure in the primary AZ

**Expected behavior:**

1. RDS detects primary instance is unavailable.
2. RDS promotes the standby in us-east-1b to primary. The DNS endpoint (`ecommerce-mysql.<identifier>.us-east-1.rds.amazonaws.com`) is updated to point to the new primary.
3. Existing database connections from ECS tasks are terminated. Tasks attempting to use those connections get connection errors.
4. Application reconnects using the same endpoint URL (unchanged). PyMySQL raises an exception; the current code doesn't have retry logic, so individual requests that were in-flight during the failover will return 500.
5. After reconnection (typically 30–120 seconds from failover start), the application resumes normal operation.

**Validation:**

```bash
# Trigger a manual failover (requires RDS reboot with failover)
aws rds reboot-db-instance \
  --db-instance-identifier ecommerce-mysql \
  --force-failover

# Monitor RDS events
aws rds describe-events \
  --source-identifier ecommerce-mysql \
  --source-type db-instance \
  --duration 60

# Watch application during failover
watch -n 2 curl -s -o /dev/null -w "%{http_code}" http://<ALB-DNS>/products
```

Expected: mostly 200s with a window of 500s or connection timeouts during the failover period (typically under 2 minutes).

**Production improvement — retry logic:**

The current application doesn't handle transient connection failures gracefully. A proper production implementation would include:

```python
# Connection pooling with retry
import pymysql
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=10)
)
def get_db_connection():
    return pymysql.connect(
        host=os.getenv('DB_HOST'),
        ...
        connect_timeout=5
    )
```

Or better: use SQLAlchemy with a connection pool that handles reconnection automatically. The goal is that a 60-second RDS failover causes a brief degradation (some requests retry and succeed) rather than a hard failure window.

---

## Scenario 4: SSM Unavailable at Container Startup

**What triggers this:**
- SSM regional endpoint is unreachable from the VPC
- ECS execution role loses permission to SSM (policy change, accidental detach)
- SSM parameter was deleted or renamed

**Expected behavior:**

The ECS task fails before the application process ever starts. The stop reason in `describe-tasks` will show:

```
ResourceInitializationError: unable to pull secrets or registry auth:
unable to retrieve secrets from ssm: AccessDeniedException
```

ECS will attempt to restart the task (based on the service's restart policy). All restarts will fail for the same reason. The service will loop in a start → fail → start cycle. CloudWatch will show no application logs because the container never reached the CMD phase.

**Validation:**

```bash
# Temporarily revoke SSM permission from execution role (destructive — don't do in prod)
# Easier: check that the parameter exists and the ARN in task definition matches

aws ssm get-parameter \
  --name "/ecommerce/db_password" \
  --with-decryption

# If this fails with AccessDeniedException, the problem is IAM
# If it returns the parameter, check the ARN in the task definition matches exactly
```

**Why this matters:**

This was the first bug encountered during the ECS migration. The execution role was missing `ssm:GetParameters` (plural). `ssm:GetParameter` (singular) was present but ECS uses the batch API under the hood. One missing permission, tasks completely unable to start. The fix was adding both `ssm:GetParameter` and `ssm:GetParameters` to the execution role policy.

---

## Scenario 5: GitHub Actions Deployment Stalls

**What triggers this:**
- New tasks are stuck in `PROVISIONING` or `PENDING` state
- ECS can't pull the image from ECR (IAM, network, or image tag issue)
- Task definition references an image tag that no longer exists in ECR

**Expected behavior:**

With `wait-for-service-stability: true` in the GitHub Actions workflow, the deployment step will time out after a set period (default ~10 minutes for the AWS action). GitHub Actions will mark the workflow as failed.

Meanwhile, ECS will continue attempting to start tasks. Old tasks remain running. Eventually ECS will stop trying if tasks consistently fail to start.

**Validation:**

```bash
# Check what ECS is doing
aws ecs describe-services \
  --cluster ecommerce-cluster \
  --services ecommerce-service

# Check if tasks are stuck in PROVISIONING
aws ecs list-tasks \
  --cluster ecommerce-cluster \
  --desired-status RUNNING

# Check stopped tasks for reason
aws ecs describe-tasks \
  --cluster ecommerce-cluster \
  --tasks <task-arn> \
  --query "tasks[*].{status:lastStatus,stopped:stoppedReason}"
```

**Common root causes in order of frequency:**

1. Execution role missing ECR pull permission (`ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`)
2. ECR image tag doesn't exist (deployment pushed to ECR, but the task definition was updated with a different tag)
3. ECS tasks SG doesn't allow outbound HTTPS to ECR endpoints (443 egress should be 0.0.0.0/0)
4. VPC routing issue preventing the task from reaching ECR (NAT Gateway problem)
