# Production Readiness

This document outlines what would need to change before this architecture could run production workloads with real users. Not everything on this list needs to be done at once — the point is to be clear-eyed about what the current demo environment doesn't handle.

The items are grouped roughly by urgency. The first section covers gaps that would cause real problems quickly. The later sections cover things that matter at scale.

---

## Immediate: Things That Would Break Under Real Use

### HTTPS / TLS Termination

The current ALB listens on port 80 over plain HTTP. Any application handling user data (even just login credentials) needs HTTPS.

Required:
- ACM certificate for the domain (free, auto-renews)
- ALB HTTPS listener on port 443
- HTTP → HTTPS redirect rule on the port 80 listener
- Route 53 hosted zone + A record pointing to the ALB DNS

This is probably the fastest path from "demo" to "presentable to a real user." Takes about an hour if you already have a domain.

### Database Credentials Rotation

Current state: DB_PASSWORD is stored in SSM, created once manually, never rotated. If the credential is compromised, there's no automatic detection and the rotation process is manual.

Production approach: migrate to AWS Secrets Manager with RDS rotation enabled. Secrets Manager can automatically rotate the RDS password on a schedule, updating both the Secrets Manager value and the RDS instance in sync. ECS tasks pick up the new password on next restart.

The application code doesn't change — it still reads `DB_PASSWORD` from the environment. The infrastructure wiring changes.

### Application-Level Error Handling and Retry Logic

The current application doesn't handle transient errors gracefully:
- No retry on DB connection failure (matters during RDS failover — see failure-scenarios.md)
- No connection pooling (each request opens a new PyMySQL connection; under load, this becomes a bottleneck)
- No request timeout enforcement

Minimum for production:
```python
# Use SQLAlchemy with pool_pre_ping to handle stale connections
from sqlalchemy import create_engine
engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,      # Test connections before use
    pool_size=5,             # Max persistent connections
    max_overflow=10,         # Burst capacity
    connect_args={"connect_timeout": 5}
)
```

`pool_pre_ping=True` alone eliminates most "connection lost" 500 errors during RDS failovers.

---

## Scalability: Things That Break at Load

### Auto Scaling for ECS

Current: `desired_count = 2`, fixed. A traffic spike either saturates the two tasks or doesn't, with no ability to adapt.

Production: Application Auto Scaling targeting CPU utilization or ALB request count per target.

```hcl
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/ecommerce-cluster/ecommerce-service"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
```

Scale-in cooldown matters here — aggressive scale-in during a traffic spike can cause oscillation. Start conservative (300-600 second scale-in cooldown).

### RDS Right-Sizing

Current: `db.t3.micro` (1 vCPU, 1GB RAM). This handles the demo fine. Under real product load, the first things to go are:
1. Connection count (t3.micro supports ~66 max connections)
2. Memory for InnoDB buffer pool

At minimum: `db.t3.small` doubles RAM (2GB). For read-heavy workloads, add a read replica and route read queries to it.

### NAT Gateway Per AZ

Current: single NAT Gateway in us-east-1a. If us-east-1a has an issue, ECS tasks in us-east-1b lose outbound internet access (can't reach ECR, SSM, CloudWatch).

Add a second NAT Gateway in us-east-1b and update the us-east-1b private subnet route table to use it. Roughly doubles the NAT cost (~$32/month → ~$64/month), but this is table stakes for an AZ-resilient architecture.

---

## Observability: Things That Make Incidents Longer

### Structured Logging

Current application logs are unstructured strings going to CloudWatch. Finding a specific error requires either luck or CloudWatch Insights queries that are harder to write against unstructured data.

Production approach: emit structured JSON logs.

```python
import json, logging

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "message": record.getMessage(),
            "request_id": getattr(record, "request_id", None),
        })
```

With structured logs, CloudWatch Insights queries become straightforward:

```
fields @timestamp, level, message, request_id
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

### CloudWatch Alarms

There are no alarms configured. An outage currently requires either a user complaint or someone actively watching the console.

Minimum alarm set:
- ALB `HTTPCode_Target_5XX_Count` > 10 per minute → SNS notification
- ECS `RunningTaskCount` < 2 → immediate alert
- RDS `DatabaseConnections` > 50 (approaching t3.micro limit)
- RDS `FreeStorageSpace` < 2GB

```hcl
resource "aws_cloudwatch_metric_alarm" "task_count_low" {
  alarm_name          = "ecommerce-task-count-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 2
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = "ecommerce-cluster"
    ServiceName = "ecommerce-service"
  }
}
```

### Distributed Tracing

For a multi-service architecture, CloudWatch Logs alone doesn't give you request-level visibility across the ALB → ECS → RDS → DynamoDB path. AWS X-Ray adds tracing with minimal code change:

```python
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.ext.fastapi.middleware import XRayMiddleware

app.add_middleware(XRayMiddleware, recorder=xray_recorder)
```

This is lower priority than alarms, but becomes important once you're debugging latency issues or trying to understand which part of the request path is slow.

---

## Security Hardening

### WAF on the ALB

Current: ALB accepts all HTTP traffic on port 80, no filtering. For public-facing applications, AWS WAF adds:
- Rate limiting (prevents basic DDoS and credential stuffing)
- Managed rule groups (OWASP Top 10, known bad IPs)
- Geo-blocking if needed

WAF costs ~$5/month base + per-rule and per-request fees. Manageable for most applications.

### Replace Long-Lived IAM Keys with OIDC

GitHub Actions currently uses long-lived IAM access keys stored as GitHub Secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`). These are a liability — if the secrets are leaked (compromised workflow, third-party action vulnerability), they're valid until manually rotated.

OIDC replaces this with short-lived credentials: GitHub Actions requests a token from AWS using the OIDC trust, gets temporary credentials valid for the duration of the workflow, credentials expire automatically.

```yaml
# GitHub Actions workflow change
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::<account>:role/github-actions-deploy
    aws-region: us-east-1
    # No access key or secret key — replaced by OIDC
```

This requires an IAM Identity Provider (OIDC) configured in the AWS account and a role with the appropriate trust policy. One-time setup.

### VPC Endpoints for AWS Services

ECS tasks in private subnets currently route ECR, SSM, and CloudWatch traffic through the NAT Gateway. VPC Interface Endpoints for these services:
- Keep traffic within the AWS network (no internet traversal)
- Eliminate NAT data processing charges for these traffic types
- Reduce attack surface (fewer reasons for outbound internet access from private subnets)

Required endpoints: `com.amazonaws.us-east-1.ecr.api`, `com.amazonaws.us-east-1.ecr.dkr`, `com.amazonaws.us-east-1.ssm`, `com.amazonaws.us-east-1.logs`, `com.amazonaws.us-east-1.s3` (for ECR layer storage).

Cost: ~$7.30/month per interface endpoint. Worth it once ECR/CloudWatch data volume is significant.

---

## Deployment Process

### Blue/Green Deployment

Current rolling deployment has a window where both old and new tasks are serving traffic simultaneously. This is fine for compatible changes, but problematic for:
- Breaking API changes (old clients hitting new code, or vice versa)
- Database schema migrations (both versions running against the same schema simultaneously)

Blue/green solves this: the new version is fully deployed to a separate target group before any traffic is shifted. Traffic switches atomically (or gradually, using weighted routing). If something's wrong, you switch back instantly.

AWS CodeDeploy supports blue/green for ECS. More operationally complex than rolling, but the right pattern for applications with database migrations.

### Database Migration Strategy

There's currently no formal process for database schema changes. In production, schema migrations need to:
1. Be backwards-compatible with the current running code (so both old and new code can work during the deployment window)
2. Be tracked and versioned (Alembic for SQLAlchemy, Flyway, or Liquibase)
3. Be run as a separate step before deploying new application code

Expand-contract pattern: add the new column, deploy code that works with both old and new schema, remove the old column in a subsequent migration. Avoids the case where the migration runs and the new application code isn't deployed yet (or vice versa).

---

## Cost Projection at Production Scale

For reference, current demo cost is ~$2.50/day. A minimal production configuration would look roughly like:

| Component | Demo | Production (minimal) |
|---|---|---|
| ECS Fargate (2 tasks) | ~$0.50/day | ~$1.00/day (larger tasks) |
| RDS t3.micro | ~$0.60/day | ~$1.20/day (t3.small) |
| NAT Gateway | ~$1.10/day | ~$2.20/day (2x AZ) |
| ALB | ~$0.25/day | ~$0.50/day |
| WAF | — | ~$0.17/day |
| Secrets Manager | — | ~$0.01/day |
| **Total** | **~$2.50/day** | **~$5.10/day** |

This is the floor. Auto-scaling ECS tasks and increased NAT data transfer from real traffic will add to it. But the architecture is designed so that cost scales with usage — you're not paying for capacity you don't need.
