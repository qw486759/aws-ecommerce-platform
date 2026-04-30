# ADR-004: Secrets Management — SSM Parameter Store

## Status
Accepted

## Context

The application needs the RDS database password at runtime. The question is where that secret lives and how it gets into the container.

The naive approach — hardcoding the password in the task definition or Terraform variables — is immediately problematic. Task definitions are visible in the AWS console. Terraform state files (`terraform.tfstate`) contain plaintext values for everything Terraform manages. If the state file is stored in S3 without proper access controls, or checked into a git repository by mistake, the password is exposed.

Beyond the storage problem, there's a rotation problem. If the password needs to change (compromised credential, routine rotation, offboarding), a hardcoded value requires rebuilding and redeploying the image or updating the task definition — operational friction that discourages rotation.

## Decision

Store the RDS password in AWS Systems Manager Parameter Store as a `SecureString`. Reference it by ARN in the ECS task definition's `secrets` block. ECS fetches the value at container startup and injects it as an environment variable. The application reads it via `os.getenv('DB_PASSWORD')`.

```
# Stored once, manually:
aws ssm put-parameter \
  --name "/ecommerce/db_password" \
  --value "<password>" \
  --type SecureString

# Referenced in task definition:
secrets = [{
  name      = "DB_PASSWORD"
  valueFrom = "arn:aws:ssm:us-east-1:<account>:parameter/ecommerce/db_password"
}]
```

IAM: the ECS execution role has `ssm:GetParameter` and `ssm:GetParameters` scoped to `arn:aws:ssm:us-east-1:<account>:parameter/ecommerce/*`. No broader access.

## Alternatives Considered

**Environment variable in task definition (plaintext)**

Simple, but the password appears in:
- Terraform state file
- ECS task definition (visible in AWS console to anyone with `ecs:DescribeTaskDefinition`)
- GitHub Actions logs if you're not careful about what gets echoed

Not acceptable for anything beyond a local throw-away demo.

**AWS Secrets Manager**

The "proper" production choice. Secrets Manager supports automatic rotation (built-in for RDS — it can rotate the password and update the RDS instance in sync). It also has a richer API and better audit trail via CloudTrail.

The reason it wasn't chosen here: cost. Secrets Manager charges $0.40/secret/month plus $0.05 per 10,000 API calls. SSM Parameter Store `SecureString` parameters are free. For a demo project, there's no functional difference — the rotation capability of Secrets Manager isn't being used, and the audit trail doesn't matter yet.

If this were a production system handling real user data, Secrets Manager would be the right call. The automatic rotation integration with RDS alone justifies the cost — manual password rotation is exactly the kind of operational task that gets skipped until something breaks.

For the upgrade path, switching from SSM to Secrets Manager requires:
1. Moving the secret to Secrets Manager
2. Updating the `valueFrom` ARN in the task definition
3. Updating the execution role policy to use `secretsmanager:GetSecretValue` instead of `ssm:GetParameter`

No application code changes needed — the container still sees it as an environment variable.

**Docker secrets / mounted files**

Docker Swarm has a secrets mechanism that mounts secrets as files. ECS Fargate doesn't support this natively. Not applicable here.

**Baking credentials into the image**

Not considered seriously. An image in ECR with credentials embedded is a significant security liability — anyone with ECR pull access would have the database password. Beyond that, rotating the credential requires rebuilding every image that contains it.

## Consequences

**Positive:**
- Password never appears in Terraform state, task definition console view, or application logs
- Encrypted at rest via AWS KMS (SSM default key)
- Access is controlled by IAM — execution role can read this path, nothing else can
- Changing the password doesn't require a new image — update SSM, force a new task deployment, done
- The path structure (`/ecommerce/db_password`) allows the execution role policy to use wildcards by application prefix, making it easy to add new secrets later without policy changes

**Negative / Trade-offs:**
- Adds a dependency on SSM availability at container startup. If SSM is unreachable, tasks fail to start. In practice, SSM is a regional service with very high availability — this is a theoretical concern, not a practical one.
- The password is still plaintext once it's inside the running container as an environment variable. An attacker with container exec access (or a process that dumps env vars) would have it. This is an accepted limitation of environment-variable-based secrets injection.
- No automatic rotation. Password rotation is a manual process: update SSM value, redeploy tasks. In production, this would be addressed by migrating to Secrets Manager with RDS rotation.

**On the decision to use SSM manually vs. Terraform-managed:**

The SSM parameter is created manually (via CLI) and deliberately not managed by Terraform. If it were in Terraform, the value would appear in `terraform.tfstate`. Manual creation keeps the secret out of any IaC artifacts. The trade-off is that it's not reproducible via `terraform apply` — someone setting up a new environment needs to know to create this manually. This is documented in the project README.
