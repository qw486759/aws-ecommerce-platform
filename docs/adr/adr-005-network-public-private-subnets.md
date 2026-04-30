# ADR-005: Network Design — Public/Private Subnet Separation

## Status
Accepted

## Context

The application needs to be reachable from the internet while ensuring that compute instances and databases are never directly exposed. This is a standard requirement, but the specific choices around subnet layout, NAT Gateway placement, and security group chaining have real implications for cost, security posture, and operational complexity.

The VPC was created manually (not managed by Terraform) because it's shared infrastructure — destroying the Terraform stack shouldn't tear down the network. This ADR covers the reasoning for the network design itself.

## Decision

Four subnets across two availability zones:

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| Public 1a | 10.0.1.0/24 | us-east-1a | ALB, NAT Gateway |
| Public 1b | 10.0.2.0/24 | us-east-1b | ALB |
| Private 1a | 10.0.3.0/24 | us-east-1a | ECS tasks, RDS primary |
| Private 1b | 10.0.4.0/24 | us-east-1b | ECS tasks, RDS standby |

Public subnets have a route table entry pointing to the Internet Gateway. Private subnets route outbound traffic through a NAT Gateway (placed in the public subnet). There is no inbound path from the internet to any resource in the private subnets.

Security group chain:
- ALB SG: allows inbound 0.0.0.0/0 on port 80
- ECS tasks SG: allows inbound from ALB SG on port 8000 only
- RDS SG: allows inbound from ECS tasks SG on port 3306 only

## Alternatives Considered

**Everything in public subnets**

Simpler — no NAT Gateway, no private routing complexity. But EC2/ECS tasks and RDS would need to either have public IPs or have security groups as the only defense.

The problem with relying on security groups alone: security groups are correct until they're not. A misconfigured rule, an emergency SSH access granted "temporarily," a new resource created by someone who didn't know the conventions — any of these can expose instances directly to the internet. Defense in depth means not having a single control point.

More fundamentally: putting RDS in a public subnet is hard to justify to any security reviewer. The database should never be reachable from outside the VPC, full stop.

**Single AZ**

Would cut costs (one NAT Gateway instead of one active, lower ALB cost). The trade-off: a single AZ failure takes down the entire application. RDS Multi-AZ requires two AZs anyway — the standby has to be in a different AZ from the primary, otherwise the failover doesn't actually improve availability.

For a demo it would technically be fine, but the goal was to show a production-viable architecture. Single-AZ is not that.

**NAT Gateway in each AZ**

For strict high availability, you'd want one NAT Gateway per AZ — if the NAT Gateway's AZ goes down, private subnet instances in other AZs lose outbound access. The current design uses a single NAT Gateway in us-east-1a.

This is a deliberate cost trade-off: a second NAT Gateway would roughly double the NAT cost (~$0.045/hour × 2). For the demo workload, the outbound traffic volume is minimal, and losing outbound access from us-east-1b for the duration of an AZ failure is acceptable. In production, you'd want NAT Gateway per AZ.

**VPC endpoints for AWS services**

ECS tasks in private subnets need to reach ECR (to pull images), SSM (to fetch secrets), and CloudWatch (to push logs). Without VPC endpoints, this traffic goes out through the NAT Gateway. With VPC endpoints, it stays within the AWS network — faster and the data transfer charge is zero.

Not implemented in this version because it adds complexity (multiple interface endpoints, each with its own security group and DNS resolution behavior) and the cost savings are minimal at demo traffic volumes. At production scale with high ECS task counts and frequent deployments, VPC endpoints for ECR, SSM, and CloudWatch would meaningfully reduce NAT costs and improve reliability.

## Consequences

**Positive:**
- No ECS task or database instance is directly internet-reachable, regardless of security group configuration
- ALB is the single entry point for all application traffic — easy to audit, easy to apply WAF rules later
- Multi-AZ placement means an AZ failure doesn't take down the application
- Security group chaining (ALB → ECS → RDS) means each tier can only be accessed by the tier in front of it; lateral movement within the VPC is constrained

**Negative / Trade-offs:**
- NAT Gateway cost: ~$0.045/hour + $0.045/GB processed. For a demo with low traffic, this is the second-largest ongoing cost after RDS. For production with significant outbound traffic, NAT Gateway costs can become significant — at that point, VPC endpoints for AWS services become worth implementing.
- Private subnets add routing complexity. During initial setup, the private route tables weren't associated with the subnets correctly, causing connectivity issues that required `terraform import` to resolve.
- ALB requires at least two subnets in different AZs, both of which must be public. This is an AWS constraint, not a design choice.

**A real problem that came up:**

During the migration from EC2 to ECS Fargate, the RDS security group only allowed inbound from the EC2 security group. When ECS tasks started — with a different security group — one task landed in a subnet where it shared a security group with EC2 (works), and the other landed in a subnet where only the ECS tasks SG applied (blocked). Half the ALB targets were healthy, half were not.

The fix was adding the ECS tasks SG as an allowed source in the RDS inbound rules. The lesson: when adding a new compute resource type, always audit the downstream security group rules. The security group chain works exactly as designed — it just needs to be kept up to date when the architecture evolves.
