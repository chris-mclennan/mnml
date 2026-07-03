---
title: Cloud agents runner (ECS) — configuration
description: Configure mnml's ECS-backed cloud-agent runner via the `[cloud_agents]` and `[jira]` config sections. The feature is a no-op until configured — safe defaults for the crates.io release. Covers the full field reference, env-var overrides, and end-to-end setup.
---

The Cloud Agents panel surfaces long-running agent runs that live outside your laptop — an ECS task on your own AWS account that the runner container fires up, writes progress into DynamoDB, uploads artifacts to S3, and (optionally) opens a PR when it's done. mnml renders those rows alongside the local Claude/Codex sessions in the Agents panel and lets you jump to CloudWatch logs / S3 / Jira / the PR from a single detail pane.

**The feature is a no-op until you configure `[cloud_agents]`.** No rail rows, no wizard entry, no trigger. The rest of mnml works unchanged.

## Minimum viable setup

Drop this into `~/.config/mnml/config.toml`:

```toml
[jira]
domain        = "acme.atlassian.net"
ticket_prefix = "PROJ-"

[cloud_agents]
label                   = "Acme cloud runner"
short_id                = "acme"
region                  = "us-east-1"
account_id              = "123456789012"
runs_table              = "acme-runner-runs"
cluster                 = "acme-runner"
task_definition         = "acme-runner-claude-runner"
sg_export_name          = "AcmeRunnerEcsSecurityGroupId"
log_group               = "/ecs/acme-runner/claude-runner"
aws_profile_fallback    = "acme-dev"
s3_artifacts_bucket     = "acme-claude-artifacts"
default_workspace_label = "acme"
```

Restart mnml. The Cloud Agents section lights up in the activity bar; `<leader>+n` (or the palette command `cloud_agents.new_run`) prompts for a Jira ticket and fires an ECS task.

## `[jira]` — Jira wiring

Two fields, both optional. Empty = feature no-op (no ticket URL rendered, no prefix validation).

| Field | Type | Env override | Default | Purpose |
|---|---|---|---|---|
| `domain` | string | `MNML_JIRA_DOMAIN` | `""` | The org's Jira instance (e.g. `"acme.atlassian.net"`). Used to build ticket URLs — `<ticket>` → `https://<domain>/browse/<ticket>`. Empty ⇒ the "Jira" chip in the cloud-run detail pane doesn't render. |
| `ticket_prefix` | string | `MNML_JIRA_TICKET_PREFIX` | `""` | The org's canonical ticket prefix (e.g. `"PROJ-"`). Used to validate ticket ids in the ECS runner trigger + as the placeholder in the new-run wizard's input. When empty, ticket validation accepts any `^[A-Z]+-\d+$` shape; the wizard shows `PROJ-` as a neutral placeholder. |

Env vars win over config-file values.

## `[cloud_agents]` — ECS runner infrastructure

All fields default to empty strings. When `region` or `runs_table` is empty, `is_enabled()` returns false and the entire feature no-ops.

### Identity

| Field | Env override | Purpose |
|---|---|---|
| `label` | — | Human label shown in the wizard's runner picker and the Cloud Agents section header (e.g. `"Acme cloud runner"`). Falls back to `"ECS runner"`. |
| `short_id` | — | Short slug used in agent-row tag chips like `☁acme` (e.g. `"acme"`). Falls back to `"ecs"`. |

### AWS wiring

| Field | Env override | Purpose |
|---|---|---|
| `region` | `MNML_CLOUD_AGENTS_REGION` | AWS region the runner stack lives in (e.g. `"us-east-1"`). |
| `account_id` | — | AWS account id. Used to build CloudWatch console URLs. |
| `runs_table` | — | DynamoDB table storing run records. Scanned every ~30s by the Cloud Agents refresh worker. |
| `cluster` | — | ECS cluster name. |
| `task_definition` | — | ECS task definition family the trigger fires (via `aws ecs run-task`). |
| `sg_export_name` | — | CloudFormation export name that resolves to the ECS task's security-group id. Trigger looks this up via `aws cloudformation list-exports`. |
| `log_group` | — | CloudWatch log group for the runner container — feeds the detail pane's logs tail. |
| `aws_profile_fallback` | `MNML_AWS_PROFILE` | AWS profile tried when the caller's default profile isn't authenticated (e.g. `"acme-dev"`). Lets Cloud Agents refresh work when your default profile is SSO-expired but a role profile still has valid creds. |
| `s3_artifacts_bucket` | — | S3 bucket where the runner writes per-run artifacts. Empty ⇒ no S3-console chip is rendered on cloud-run rows. |
| `default_workspace_label` | — | Cosmetic display fallback when a run row has no ticket id (e.g. `"acme"`). Falls back to `"cloud"`. |

### Env-var overrides

Two overrides are per-machine-friendly — they let you keep the same `~/.config/mnml/config.toml` across machines while pointing at different regions / AWS profiles from a shell rc file:

```sh
export MNML_CLOUD_AGENTS_REGION="us-west-2"
export MNML_AWS_PROFILE="my-team-dev"
```

## Data model — what the runner writes

The Cloud Agents panel reads the DynamoDB `runs_table` and expects each row to carry these attributes (all `S` = string, `N` = number):

| Attribute | Type | Notes |
|---|---|---|
| `runId` | S | Primary key. Unique per run. |
| `ticket` | S | Jira ticket id (used to build the Jira chip URL). |
| `flow` | S | Which flow/pipeline this run represents. |
| `source` | S | `"manual"` for mnml-triggered runs, whatever your infra sets otherwise. |
| `state` | S | `"started"` / `"staged"` / `"approved"` / `"shipped"` / `"dismissed"` / `"failed"`. Drives the agent-row state color. |
| `createdAt` | S | ISO-8601 timestamp. |
| `finishedAt` | S | ISO-8601, optional. |
| `approvalIntent` | S | Optional. |
| `s3ArtifactPrefix` | S | Optional. Used to derive the S3-console chip when set. |
| `slackTs` | S | Optional. |
| `prUrl` | S | Optional. Shown on the detail pane header when set. |
| `lastRunStatus` | S | Optional. |
| `lastError` | S | Optional. Shown in the last-line summary when state = failed. |

State lifecycle: `started → staged → approved → shipped` (with `dismissed` / `failed` off-ramps).

## Trigger flow — `cloud_agents.new_run`

Palette: `cloud_agents.new_run`. Chord: none bound by default.

1. Prompt appears: `"New cloud run — Jira ticket (<prefix>NNNN)"`. Type a ticket id and hit Enter.
2. mnml validates the ticket (must be `^[A-Z]+-\d+$`; must start with `[jira] ticket_prefix` when configured).
3. Background worker fires:
   - `aws ec2 describe-subnets --filters Name=tag:Tier,Values=Private` — resolve private subnets.
   - `aws cloudformation list-exports --query …` — resolve the security group.
   - `aws ecs run-task` — start the task with the container env (RUN_ID, TICKET, FLOW, CLAUDE_COMMAND).
   - `aws dynamodb put-item` — seed the `runs_table` row so the panel picks it up immediately (before the container's own row-write on startup).
4. Toast reports `"fired ECS run for <ticket>"` on success; `"cloud run failed: <reason>"` otherwise.

The panel refreshes every ~30s. The row appears immediately after the seed; state updates flow in as the container writes them.

## Auth

The trigger + panel scan shell out to the `aws` CLI. Auth strategy:

1. If your default profile has valid credentials (SSO or otherwise), that's used.
2. If the default profile call fails and `aws_profile_fallback` is set (or `MNML_AWS_PROFILE` is exported), the tool retries with `AWS_PROFILE=<fallback>`.
3. If both fail, the panel silently shows zero rows (no error surfaced — a stale SSO session is a routine state, not something worth toast-spamming about).

The scan runs on a 30s cadence. If you'd like to force-refresh: `cloud_agents.refresh` palette command.

## Related config

- `[[ui.integration_icon]]` — the Cloud Agents rail chip has default-off + can be reconfigured / toggled via right-click.
- `[cloud_run.defaults]` — the panel's quick-fire prompt input's saved defaults. Written by the wizard; edited via the "change defaults" chip on the wizard's runner-picker step.

## Troubleshooting

- **Panel shows zero rows even though the table has rows.** Check `region` — the panel scans `<runs_table>` in `<region>` only. If your table lives in a different region, `MNML_CLOUD_AGENTS_REGION` overrides.
- **Trigger fails with `couldn't resolve CFN export`.** Verify the CFN export name matches your stack — `aws cloudformation list-exports --query "Exports[?Name=='$sg_export_name'].Value"` should return the SG id.
- **Trigger fails with `couldn't resolve private subnets`.** Ensure your subnets are tagged `Tier=Private`.
- **Chip on the rail doesn't render.** Cloud Agents is a builtin activity-bar section — always renders even when `[cloud_agents]` is unset. If you're not seeing the section at all, check the sidebar's `[[ui.integration_icon]]` config didn't disable it.

## Related

- [Bridge / Mount protocol](/manual/bridge-mount/) — the SDK siblings use to add their own cloud-agent panels.
- [Settings & configuration](/manual/settings/) — general config file overview.
