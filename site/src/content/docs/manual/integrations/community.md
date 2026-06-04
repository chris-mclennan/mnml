---
title: Community integrations
description: A list of community-built mnml integrations. Send a PR to add yours.
---

mnml's integration model lets anyone publish a standalone CLI that doubles as a hosted mnml pane. This page is a directory of those.

To add your integration: send a PR to [mnml](https://github.com/chris-mclennan/mnml) editing `site/src/content/docs/manual/integrations/community.md` with one row in the table below. The bar is low — it should build, run, and not be malware. We won't audit your code, won't gate on quality, and won't take ownership of your repo.

If you haven't built one yet, see [Building integrations](/manual/integrations/building/).

## First-party

Maintained by the mnml family. These are the reference implementations for the architecture — clone any of them to bootstrap your own.

### Ticket viewers

| Integration | Backend | Repo |
|---|---|---|
| `mnml-tickets-jira` | Atlassian Jira | [chris-mclennan/mnml-tickets-jira](https://github.com/chris-mclennan/mnml-tickets-jira) |
| `mnml-tickets-github` | GitHub Issues + Pulls | [chris-mclennan/mnml-tickets-github](https://github.com/chris-mclennan/mnml-tickets-github) |

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
