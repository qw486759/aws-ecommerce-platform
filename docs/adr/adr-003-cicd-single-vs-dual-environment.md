# ADR-003: CI/CD Strategy — Single Environment vs Dual Environment with Approval Gate

## Status
Accepted — both strategies implemented; default is single-environment

## Context

The project needed a CI/CD pipeline that could be demonstrated to clients with different risk tolerances. The question wasn't just "how do we deploy" — it was "what deployment governance model makes sense, and when?"

Two realistic scenarios:

**Scenario A:** Personal project, internal tool, or early-stage product. Small team, rapid iteration. The person pushing code is also the person who cares most if it breaks. Minimizing friction to production is a feature, not a risk.

**Scenario B:** Application with real users, payment flows, or compliance requirements. Someone other than the developer needs to verify a change before it goes live. A staging environment gives reviewers something to click around in. An approval gate ensures production deployments are intentional.

The challenge: these aren't just different configurations — they represent different operational philosophies, and neither is universally correct.

## Decision

Implement both strategies as separate GitHub Actions workflow files:

- `deploy.yml` — single environment, pushes directly to production on `main`
- `deploy-staging.yml` — dual environment with staging auto-deploy and a GitHub Approval Gate before production

Clients choose based on their situation. Both workflows are in the repository. The repo README documents when to use each.

## Alternatives Considered

**Always use dual environment**

The "enterprise-safe" default. Problem: it adds process overhead that slows down solo developers and small teams. The cost is $1.30/day for a staging environment that's always running (one additional Fargate task + its share of ALB/NAT). Over a month that's ~$40 — not huge, but also unnecessary if nobody is using staging between deployments.

More importantly: enforcing approval gates on a solo project creates the same friction without the benefit. The reviewer is the same person as the deployer.

**Always use single environment**

Simpler, cheaper, faster. But not appropriate for anything with real users. One bad push to `main` goes directly to production. For internal tools or early prototypes this is fine; for a client with a payment integration it's not.

**Feature flags instead of staging**

Came up briefly. The idea: deploy to production, but keep new features behind flags. Validate in production with controlled rollout. This is how large companies (Netflix, Facebook) handle it — they don't have traditional staging environments.

The problem: feature flags add application complexity and require an additional service (LaunchDarkly, AWS AppConfig, etc.). Overkill for this project scope. Worth considering at a later maturity stage.

**Branch-based environments (one environment per PR)**

Would give every pull request its own isolated environment. Clean from a testing perspective; expensive and complex to manage. Requires dynamic environment provisioning (Terraform Workspaces or similar). Not practical for a demo project. Filed for future consideration.

## Implementation Notes

The approval gate in `deploy-staging.yml` is implemented using GitHub Environments:

```yaml
approve-production:
  environment: production
```

This single field causes GitHub Actions to pause the workflow and require approval from designated reviewers before the production deployment job runs. Setup is in repo Settings → Environments → production → Required reviewers.

The staging ECS service uses `desired_count = 1` (vs. 2 in production). Staging doesn't need high availability — it's for functional validation, not load testing. This halves the staging compute cost.

## Consequences

**Single-env (`deploy.yml`):**
- Deploy time: ~5 minutes end to end
- Daily cost: ~$2.50
- Risk: One broken push = production incident
- Best for: Solo developers, internal tools, early-stage products

**Dual-env (`deploy-staging.yml`):**
- Deploy time: ~10 minutes + reviewer wait time
- Daily cost: ~$3.80 (when staging runs 24/7; less if staging is torn down between uses)
- Risk: Reduced — staging catches environment-specific issues before production
- Best for: Teams with real users, compliance requirements, or non-developer stakeholders who need to verify changes

**On the cost framing:**

The $1.30/day delta for the dual-environment approach is roughly the cost of one production incident's first hour of engineering time. For any application with meaningful traffic, the staging environment pays for itself on the first catch. The framing I use with clients: it's not overhead, it's cheap insurance.

**Limitation worth noting:**

Staging and production share the same Docker image (tagged by commit SHA). What staging doesn't replicate: production traffic volume, production data volume, and any data migration complexity. It catches configuration errors and basic functionality regressions well. It doesn't replicate performance characteristics under load.
