# Environment Switching Guide

This project supports two deployment strategies.
Switch between them based on project requirements.

---

## Default: Single Environment (Direct to Production)

Suitable for: personal projects, small teams with fast iteration cycles

Flow:
  push to main
    -> GitHub Actions: deploy.yml
    -> pytest -> docker build -> ECR push -> ECS production rolling deploy

No additional setup required. This is the default behavior.

---

## Optional: Dual Environment (Staging -> Approval -> Production)

Suitable for: production environments with real users or compliance requirements

Flow:
  push to staging branch
    -> GitHub Actions: deploy-staging.yml
    -> pytest -> docker build -> ECR push
    -> auto deploy ECS staging
    -> manual verification
    -> GitHub Approval Gate (required reviewer clicks Approve)
    -> auto deploy ECS production

### How to Enable

Step 1: Create the staging branch
  git checkout -b staging
  git push origin staging

Step 2: Deploy staging AWS resources
  terraform plan
  terraform apply
  (ecs-staging.tf is already in the repo, no extra files needed)

Step 3: Configure GitHub Environments
  Go to: repo -> Settings -> Environments

  Create two environments:

  Name          Required Reviewers   Notes
  staging       none                 auto-passes, no approval needed
  production    add yourself         pipeline pauses here until approved

Step 4: Set GitHub Secrets (if not already done)
  Go to: repo -> Settings -> Secrets and variables -> Actions

  Add:
    AWS_ACCESS_KEY_ID      -> your IAM user access key
    AWS_SECRET_ACCESS_KEY  -> your IAM user secret key

Step 5: Push to staging branch to trigger the pipeline
  git checkout staging
  git merge main
  git push origin staging

---

## Workflow Comparison

| Item | deploy.yml (default) | deploy-staging.yml (optional) |
|------|---------------------|-------------------------------|
| Trigger | push to main | push to staging or manual |
| Jobs | 2 (test + deploy) | 5 (test + build + staging + approve + prod) |
| Approval gate | none | yes, GitHub Environment gate |
| AWS resources | production only | staging + production |
| Daily cost | ~$2.5 | ~$3.8 |
| Time to deploy | ~5 minutes | ~10 minutes + reviewer wait time |

---

## Manual Trigger (No staging branch needed)

Go to: repo -> Actions -> CI/CD to Staging and Production with Approval Gate
  -> Run workflow
  -> Select environment: staging or production
  -> Run workflow

---

## Reverting to Single Environment

1. Stop pushing to the staging branch
2. Run: terraform destroy -target=aws_ecs_cluster.staging
3. deploy.yml continues working without any changes
