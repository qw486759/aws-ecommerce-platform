# ADR-001: Use ECS Fargate for Application Compute

## Status
Accepted

## Context

The application runs containerized FastAPI workloads. The deployment model needs to support rolling updates without downtime, avoid the need for SSH access or OS-level management, and integrate cleanly with a GitHub Actions CI/CD pipeline.

Early in the project, the application ran on EC2 with `user_data` to bootstrap the environment. The core problem with that setup: code and infrastructure were coupled. Updating the application meant rebuilding the EC2 instance — roughly 10–15 minutes of downtime per deployment, plus a fragile startup script that had to be kept in sync with the application's actual dependencies.

The question became: if we're already containerizing the application anyway (for local dev consistency), what's the right way to run containers in AWS at this scale?

## Decision

Use ECS Fargate to run FastAPI containers in private subnets behind an ALB.

Tasks run in `awsvpc` network mode, each getting a dedicated ENI and private IP. The ALB routes by IP (target type `ip`), not by EC2 instance ID — a distinction that matters because Fargate has no persistent instance underneath.

CPU/memory: 256 CPU units (0.25 vCPU) and 512 MB. Deliberately minimal — this is a demo workload. In production, you'd baseline from CloudWatch metrics and right-size from there.

Desired count: 2, distributed across private subnets in us-east-1a and us-east-1b.

## Alternatives Considered

**EC2 with `user_data`**

This was the starting point. Works, but has real drawbacks:
- `user_data` runs once on first boot. If it fails, the instance is broken and needs to be replaced.
- Updating application code means terminating and re-provisioning the instance.
- No clean rollback — you'd need to keep an AMI snapshot of the last known-good version.
- AMI drift over time as dependencies diverge between what's in the script and what's actually running.

Still a reasonable choice if you're running workloads that need persistent local state, GPU access, or tight cost control on stable traffic. Doesn't apply here.

**Elastic Beanstalk**

Handles the orchestration layer for you, but adds a layer of abstraction that makes it harder to understand (and explain) what's actually happening underneath. Beanstalk manages the EC2 fleet, load balancer, and auto scaling — useful for teams that want less control, but for a demo project where the goal is to show architectural reasoning, having explicit Terraform resources for every component is better. Also less portable — Beanstalk is tightly coupled to how AWS wants to structure things.

**Lambda**

Considered for the API layer. The problem: this application uses PyMySQL to maintain persistent connections to RDS. Lambda's stateless execution model doesn't play well with connection pooling — each invocation risks creating a new DB connection, which degrades RDS performance at scale. Lambda also has cold start latency that would be visible on the `/products` endpoint.

Lambda would make more sense if the application were redesigned around RDS Proxy or if the workload were truly event-driven (async order processing, for example). Not the right fit for a synchronous REST API fronted by an ALB.

**ECS on EC2 (not Fargate)**

Worth mentioning: ECS also runs on EC2 launch type. The trade-off is roughly 20% cheaper compute, but you're back to managing EC2 instances — OS patches, instance scaling, EBS volumes. Fargate's "no server management" property is the main reason to pay the premium, especially for a project where the value is in demonstrating application architecture rather than infrastructure operations.

## Consequences

**Positive:**
- No OS patching, no SSH, no AMI management
- Rolling deployments handled natively by ECS service — no custom scripting
- Each task gets its own IAM task role; least-privilege is straightforward to implement
- CloudWatch Logs integration works out of the box via the log driver in the task definition
- Clean separation between the execution role (what ECS needs to start the container) and the task role (what the application needs to do its job)

**Negative / Trade-offs:**
- Slightly higher compute cost vs. EC2 (~15–20% premium)
- Fargate cold starts are slower than EC2 when scaling out from zero
- Container image size directly affects deployment time — worth keeping the image lean (multi-stage build helps here)
- The `awsvpc` network mode requires a sufficient ENI density budget in the subnet; for large Fargate fleets this becomes a planning concern

**Operational note:**

One non-obvious issue encountered during initial deployment: the ALB target type must be `ip`, not `instance`, when using Fargate with `awsvpc` mode. EC2-based target groups use instance IDs. Fargate tasks have no instance ID — they have an IP address in the VPC. Changing this after the fact requires recreating the target group, which is a brief outage. Worth getting right the first time.
