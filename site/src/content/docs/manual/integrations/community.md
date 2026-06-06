---
title: Community integrations
description: A list of community-built mnml integrations. Send a PR to add yours.
---

mnml's integration model lets anyone publish a standalone CLI that doubles as a hosted mnml pane. This page is a directory of those.

To add your integration: send a PR to [mnml](https://github.com/chris-mclennan/mnml) editing `site/src/content/docs/manual/integrations/community.md` with one row in the table below. The bar is low — it should build, run, and not be malware. We won't audit your code, won't gate on quality, and won't take ownership of your repo.

If you haven't built one yet, see [Building integrations](/manual/integrations/building/).

## First-party

Maintained by the mnml family. These are the reference implementations for the architecture — clone any of them to bootstrap your own.

### Tracker viewers

Issue / work trackers — issues, sprints, roadmaps, releases, dashboards.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-tracker-jira` | Atlassian Jira — JQL or auto-resolved release `fixVersion`s | [chris-mclennan/mnml-tracker-jira](https://github.com/chris-mclennan/mnml-tracker-jira) |
| `mnml-tracker-linear` | Linear — GraphQL filter or saved view ids | [chris-mclennan/mnml-tracker-linear](https://github.com/chris-mclennan/mnml-tracker-linear) |

### Forge viewers

Code-hosting forges — SCM + PRs/MRs + pipelines + reviews + issues, all under one roof.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-forge-bitbucket` | Bitbucket Cloud — PRs + Pipelines + Branches | [chris-mclennan/mnml-forge-bitbucket](https://github.com/chris-mclennan/mnml-forge-bitbucket) |
| `mnml-forge-github` | GitHub — Issues / PRs (search) + Actions workflow runs | [chris-mclennan/mnml-forge-github](https://github.com/chris-mclennan/mnml-forge-github) |
| `mnml-forge-gitlab` | GitLab (gitlab.com or self-hosted) — Merge Requests + Pipelines | [chris-mclennan/mnml-forge-gitlab](https://github.com/chris-mclennan/mnml-forge-gitlab) |
| `mnml-forge-azdevops` | Azure DevOps — Pull Requests + Builds | [chris-mclennan/mnml-forge-azdevops](https://github.com/chris-mclennan/mnml-forge-azdevops) |

### CI / build / deploy dashboards

Stand-alone CI / deploy viewers — for build and hosting platforms that aren't bundled with a forge.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-aws-codebuild` | AWS CodeBuild + CloudWatch Logs live tail (shells out to `aws` CLI) | [chris-mclennan/mnml-aws-codebuild](https://github.com/chris-mclennan/mnml-aws-codebuild) |
| `mnml-aws-cloudwatch-logs` | AWS CloudWatch Logs — tabbed log groups, severity coloring, filter patterns | [chris-mclennan/mnml-aws-cloudwatch-logs](https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs) |
| `mnml-aws-amplify` | AWS Amplify — apps, branches, deploy jobs | [chris-mclennan/mnml-aws-amplify](https://github.com/chris-mclennan/mnml-aws-amplify) |
| `mnml-aws-lambda` | AWS Lambda — function browser + detail panel, `l` chord launches CloudWatch Logs sibling | [chris-mclennan/mnml-aws-lambda](https://github.com/chris-mclennan/mnml-aws-lambda) |
| `mnml-aws-eventbridge` | AWS EventBridge — buses, rules, event-pattern + schedule detail | [chris-mclennan/mnml-aws-eventbridge](https://github.com/chris-mclennan/mnml-aws-eventbridge) |

### Test infrastructure

Test-tooling viewers — runners stay in mnml core (editor-integrated); these are the read-only inspection siblings.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-test-playwright` | Playwright `trace.zip` viewer — per-action timeline + console + errors | [chris-mclennan/mnml-test-playwright](https://github.com/chris-mclennan/mnml-test-playwright) |
| `mnml-test-cypress` | Cypress mochawesome JSON viewer — pass/fail state + failures filter + spec yank | [chris-mclennan/mnml-test-cypress](https://github.com/chris-mclennan/mnml-test-cypress) |

### Cloud filesystem viewers

Object-store browsers — browse buckets / prefixes / objects as a TUI tree. Shells out to vendor CLIs (no SDK deps).

| Integration | Backend | Repo |
|---|---|---|
| `mnml-fs-s3` | Amazon S3 — bucket tabs, prefix navigation, download, presigned URLs | [chris-mclennan/mnml-fs-s3](https://github.com/chris-mclennan/mnml-fs-s3) |

### Database viewers

| Integration | Backend | Repo |
|---|---|---|
| `mnml-db-postgres` | PostgreSQL | [chris-mclennan/mnml-db-postgres](https://github.com/chris-mclennan/mnml-db-postgres) |
| `mnml-db-mariadb` | MariaDB / MySQL | [chris-mclennan/mnml-db-mariadb](https://github.com/chris-mclennan/mnml-db-mariadb) |
| `mnml-db-redshift` | Amazon Redshift | [chris-mclennan/mnml-db-redshift](https://github.com/chris-mclennan/mnml-db-redshift) |
| `mnml-db-clickhouse` | ClickHouse | [chris-mclennan/mnml-db-clickhouse](https://github.com/chris-mclennan/mnml-db-clickhouse) |
| `mnml-db-redis` | Redis | [chris-mclennan/mnml-db-redis](https://github.com/chris-mclennan/mnml-db-redis) |
| `mnml-db-docdb` | Amazon DocumentDB / MongoDB | [chris-mclennan/mnml-db-docdb](https://github.com/chris-mclennan/mnml-db-docdb) |
| `mnml-db-dynamodb` | Amazon DynamoDB — table browser via `aws dynamodb scan` | [chris-mclennan/mnml-db-dynamodb](https://github.com/chris-mclennan/mnml-db-dynamodb) |

## Community

_Send a PR to add your integration here._

| Integration | Backend | Author | Repo |
|---|---|---|---|
| _(none yet — be the first!)_ | | | |
