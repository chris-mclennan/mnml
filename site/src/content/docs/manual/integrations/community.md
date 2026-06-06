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
| `mnml-tracker-jira` | Atlassian Jira | [chris-mclennan/mnml-tracker-jira](https://github.com/chris-mclennan/mnml-tracker-jira) |

### Forge viewers

Code-hosting forges — SCM + PRs/MRs + pipelines + reviews + issues, all under one roof.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-forge-bitbucket` | Bitbucket Cloud — PRs + Pipelines + Branches | [chris-mclennan/mnml-forge-bitbucket](https://github.com/chris-mclennan/mnml-forge-bitbucket) |
| `mnml-forge-github` | GitHub — Issues / PRs (search) + Actions workflow runs | [chris-mclennan/mnml-forge-github](https://github.com/chris-mclennan/mnml-forge-github) |
| `mnml-forge-gitlab` | GitLab (gitlab.com or self-hosted) — Merge Requests + Pipelines | [chris-mclennan/mnml-forge-gitlab](https://github.com/chris-mclennan/mnml-forge-gitlab) |
| `mnml-forge-azdevops` | Azure DevOps — Pull Requests + Builds | [chris-mclennan/mnml-forge-azdevops](https://github.com/chris-mclennan/mnml-forge-azdevops) |

### CI / build dashboards

Stand-alone CI viewers — for build platforms that aren't bundled with a forge.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-aws-codebuild` | AWS CodeBuild + CloudWatch Logs live tail (shells out to `aws` CLI) | [chris-mclennan/mnml-aws-codebuild](https://github.com/chris-mclennan/mnml-aws-codebuild) |

### Test infrastructure

Test-tooling viewers — runners stay in mnml core (editor-integrated); these are the read-only inspection siblings.

| Integration | Backend | Repo |
|---|---|---|
| `mnml-test-playwright` | Playwright `trace.zip` viewer — per-action timeline + console + errors | [chris-mclennan/mnml-test-playwright](https://github.com/chris-mclennan/mnml-test-playwright) |

### Database viewers

| Integration | Backend | Repo |
|---|---|---|
| `mnml-db-postgres` | PostgreSQL | [chris-mclennan/mnml-db-postgres](https://github.com/chris-mclennan/mnml-db-postgres) |
| `mnml-db-mariadb` | MariaDB / MySQL | [chris-mclennan/mnml-db-mariadb](https://github.com/chris-mclennan/mnml-db-mariadb) |
| `mnml-db-redshift` | Amazon Redshift | [chris-mclennan/mnml-db-redshift](https://github.com/chris-mclennan/mnml-db-redshift) |
| `mnml-db-clickhouse` | ClickHouse | [chris-mclennan/mnml-db-clickhouse](https://github.com/chris-mclennan/mnml-db-clickhouse) |
| `mnml-db-redis` | Redis | [chris-mclennan/mnml-db-redis](https://github.com/chris-mclennan/mnml-db-redis) |
| `mnml-db-docdb` | Amazon DocumentDB / MongoDB | [chris-mclennan/mnml-db-docdb](https://github.com/chris-mclennan/mnml-db-docdb) |

## Community

_Send a PR to add your integration here._

| Integration | Backend | Author | Repo |
|---|---|---|---|
| _(none yet — be the first!)_ | | | |
