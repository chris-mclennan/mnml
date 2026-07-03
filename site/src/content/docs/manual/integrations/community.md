---
title: Community integrations
description: The full mnml family — 37 first-party sibling integrations across forges, trackers, messaging, cloud infrastructure, databases, observability, testing, and more. Every sibling self-installs into mnml via `<sibling> --install` (mnml-bridge 0.3+).
---

mnml's integration model lets anyone publish a standalone CLI that doubles as a hosted mnml pane. This page is a directory of the family — 37 first-party integrations across forges, trackers, messaging, cloud infra, databases, observability, and testing.

Every sibling **self-installs** — after `cargo install <sibling-repo>`, run `<sibling> --install` and the rail chip + palette command + chord appear in mnml on next restart (or after `integrations.refresh`). See [Building integrations](/manual/integrations/building/) for the SDK contract, or [Bridge / Mount protocol](/manual/bridge-mount/) for the full API surface.

To add your integration: send a PR editing this file. The bar is low — it should build, run, and not be malware. We won't audit your code, gate on quality, or take ownership of your repo.

## First-party — the mnml family

Maintained alongside mnml. These are the reference implementations for the architecture — clone any of them to bootstrap your own.

### Forges (SCM + PRs + pipelines)

Code-hosting forges — SCM, PRs / MRs, pipelines, reviews, issues under one roof.

| Integration | Backend |
|---|---|
| [`mnml-forge-bitbucket`](https://github.com/chris-mclennan/mnml-forge-bitbucket) | Bitbucket Cloud — PRs + Pipelines + Branches ([manual](/manual/integrations/forge-bitbucket/)) |
| [`mnml-forge-github`](https://github.com/chris-mclennan/mnml-forge-github) | GitHub — Issues / PRs + Actions runs ([manual](/manual/integrations/forge-github/)) |
| [`mnml-forge-gitlab`](https://github.com/chris-mclennan/mnml-forge-gitlab) | GitLab (gitlab.com or self-hosted) — MRs + Pipelines ([manual](/manual/integrations/forge-gitlab/)) |
| [`mnml-forge-azdevops`](https://github.com/chris-mclennan/mnml-forge-azdevops) | Azure DevOps — Pull Requests + Builds ([manual](/manual/integrations/forge-azdevops/)) |

### Trackers

Issue / work trackers — issues, sprints, roadmaps.

| Integration | Backend |
|---|---|
| [`mnml-tracker-jira`](https://github.com/chris-mclennan/mnml-tracker-jira) | Atlassian Jira — JQL or auto-resolved release `fixVersion`s ([manual](/manual/integrations/tracker-jira/)) |
| [`mnml-tracker-linear`](https://github.com/chris-mclennan/mnml-tracker-linear) | Linear — GraphQL filter or saved view ids |

### Messaging

Chat, email, calendar — read + post + react + compose from the keyboard.

| Integration | Backend |
|---|---|
| [`mnml-msg-slack`](https://github.com/chris-mclennan/mnml-msg-slack) | Slack — channels, DMs, search, post, react ([manual](/manual/integrations/msg-slack/)) |
| [`mnml-msg-teams`](https://github.com/chris-mclennan/mnml-msg-teams) | Microsoft Teams — teams, chats, search, post ([manual](/manual/integrations/msg-teams/)) |
| [`mnml-msg-gmail`](https://github.com/chris-mclennan/mnml-msg-gmail) | Gmail — inbox, sent, labels, search, compose ([manual](/manual/integrations/msg-gmail/)) |
| [`mnml-msg-gcal`](https://github.com/chris-mclennan/mnml-msg-gcal) | Google Calendar — Today / Week / Upcoming panes ([manual](/manual/integrations/msg-gcal/)) |
| [`mnml-msg-buttondown`](https://github.com/chris-mclennan/mnml-msg-buttondown) | Buttondown newsletter — drafts, sent, scheduled, subscribers ([manual](/manual/integrations/msg-buttondown/)) |
| [`mnml-msg-mandrill`](https://github.com/chris-mclennan/mnml-msg-mandrill) | Mandrill transactional email — messages, templates, tags ([manual](/manual/integrations/msg-mandrill/)) |

### AWS

AWS service viewers — every sibling shells out to the `aws` CLI (no SDK deps).

| Integration | Backend |
|---|---|
| [`mnml-aws-codebuild`](https://github.com/chris-mclennan/mnml-aws-codebuild) | CodeBuild + CloudWatch Logs live tail ([manual](/manual/integrations/aws-codebuild/)) |
| [`mnml-aws-cloudwatch-logs`](https://github.com/chris-mclennan/mnml-aws-cloudwatch-logs) | CloudWatch Logs — tabbed groups, severity coloring ([manual](/manual/integrations/aws-cloudwatch-logs/)) |
| [`mnml-aws-amplify`](https://github.com/chris-mclennan/mnml-aws-amplify) | Amplify — apps, branches, deploy jobs ([manual](/manual/integrations/aws-amplify/)) |
| [`mnml-aws-lambda`](https://github.com/chris-mclennan/mnml-aws-lambda) | Lambda — functions + detail, `l` chord → CloudWatch Logs ([manual](/manual/integrations/aws-lambda/)) |
| [`mnml-aws-eventbridge`](https://github.com/chris-mclennan/mnml-aws-eventbridge) | EventBridge — buses, rules, event patterns ([manual](/manual/integrations/aws-eventbridge/)) |
| [`mnml-aws-rds`](https://github.com/chris-mclennan/mnml-aws-rds) | RDS — instances, snapshots ([manual](/manual/integrations/aws-rds/)) |
| [`mnml-aws-ecs`](https://github.com/chris-mclennan/mnml-aws-ecs) | ECS — clusters, services, task definitions ([manual](/manml/integrations/aws-ecs/)) |
| [`mnml-aws-ecr`](https://github.com/chris-mclennan/mnml-aws-ecr) | ECR — repositories, images, tags ([manual](/manual/integrations/aws-ecr/)) |
| [`mnml-aws-cognito`](https://github.com/chris-mclennan/mnml-aws-cognito) | Cognito — User Pools, recent users ([manual](/manual/integrations/aws-cognito/)) |
| [`mnml-aws-sqs`](https://github.com/chris-mclennan/mnml-aws-sqs) | SQS — queues, message peek ([manual](/manual/integrations/aws-sqs/)) |
| [`mnml-aws-sns`](https://github.com/chris-mclennan/mnml-aws-sns) | SNS — topics, subscriptions ([manual](/manual/integrations/aws-sns/)) |

### Databases

SQL + NoSQL browsers — connection tabs, query playgrounds, result tables.

| Integration | Backend |
|---|---|
| [`mnml-db-postgres`](https://github.com/chris-mclennan/mnml-db-postgres) | PostgreSQL |
| [`mnml-db-mariadb`](https://github.com/chris-mclennan/mnml-db-mariadb) | MariaDB / MySQL |
| [`mnml-db-redshift`](https://github.com/chris-mclennan/mnml-db-redshift) | Amazon Redshift |
| [`mnml-db-clickhouse`](https://github.com/chris-mclennan/mnml-db-clickhouse) | ClickHouse (HTTP + `FORMAT JSON`) |
| [`mnml-db-redis`](https://github.com/chris-mclennan/mnml-db-redis) | Redis — command playground, type-aware responses |
| [`mnml-db-docdb`](https://github.com/chris-mclennan/mnml-db-docdb) | Amazon DocumentDB / MongoDB |
| [`mnml-db-dynamodb`](https://github.com/chris-mclennan/mnml-db-dynamodb) | Amazon DynamoDB — `aws dynamodb scan` ([manual](/manual/integrations/db-dynamodb/)) |

### Cloud filesystems

Object-store browsers — buckets / prefixes / objects as a TUI tree.

| Integration | Backend |
|---|---|
| [`mnml-fs-s3`](https://github.com/chris-mclennan/mnml-fs-s3) | Amazon S3 — bucket tabs, prefix nav, download, presigned URLs ([manual](/manual/integrations/fs-s3/)) |
| [`mnml-fs-azure-blob`](https://github.com/chris-mclennan/mnml-fs-azure-blob) | Azure Blob Storage — accounts, containers, blobs, SAS ([manual](/manual/integrations/fs-azure-blob/)) |

### Observability

Metrics, logs, monitors.

| Integration | Backend |
|---|---|
| [`mnml-obs-datadog`](https://github.com/chris-mclennan/mnml-obs-datadog) | Datadog — monitors, dashboards, live-tail logs, incidents ([manual](/manual/integrations/obs-datadog/)) |

### CDN / Edge

CDN + DNS + Workers / edge functions.

| Integration | Backend |
|---|---|
| [`mnml-cdn-cloudflare`](https://github.com/chris-mclennan/mnml-cdn-cloudflare) | Cloudflare — Zones, DNS, Workers, Pages, security events ([manual](/manual/integrations/cdn-cloudflare/)) |

### Virtualization / containers

Container runtimes + orchestrators.

| Integration | Backend |
|---|---|
| [`mnml-virt-docker`](https://github.com/chris-mclennan/mnml-virt-docker) | Docker — containers, images, volumes, networks, compose ([manual](/manual/integrations/virt-docker/)) |

### Test infrastructure

Test-result inspection.

| Integration | Backend |
|---|---|
| [`mnml-test-playwright`](https://github.com/chris-mclennan/mnml-test-playwright) | Playwright `trace.zip` viewer — per-action timeline, console, errors ([manual](/manual/integrations/test-playwright/)) |
| [`mnml-test-cypress`](https://github.com/chris-mclennan/mnml-test-cypress) | Cypress mochawesome JSON viewer ([manual](/manual/integrations/test-cypress/)) |

## Community

_Send a PR to add your integration here._

| Integration | Backend | Author | Repo |
|---|---|---|---|
| _(none yet — be the first!)_ | | | |
