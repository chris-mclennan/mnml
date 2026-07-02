//! Trigger a cloud-agent run against the configured ECS cluster.
//! Shape: discover network config (private subnets + a CFN-exported
//! security group), fire `aws ecs run-task`, then seed the DynamoDB
//! run-records row so the Cloud Agents panel picks it up on the
//! next refresh.
//!
//! Shelling out to the AWS CLI matches the rest of `ecs_runner.rs`
//! and dodges ~50 transitive deps from `aws-sdk-*` crates.
//!
//! Auth: caller is expected to have an SSO profile with
//! `ecs:RunTask` + `iam:PassRole` + `dynamodb:PutItem` granted.
//! Errors surface via the toast channel.
//!
//! The feature is a no-op when `[cloud_agents]` isn't configured —
//! callers check `config.cloud_agents.is_enabled()` first.

use crate::config::{CloudAgentsConfig, JiraConfig};
use std::process::Command;
use std::time::SystemTime;

/// Outcome of `trigger_run` reported back to App via the worker
/// channel.
#[derive(Debug)]
pub enum TriggerResult {
    Ok { run_id: String, task_arn: String },
    Err(String),
}

/// Fire a cloud-agent run for `ticket`. Default flow is `triage`,
/// env `prod` — the container command line is `/triage-auto
/// <ticket> --env=prod`, matching the runner's smoke-test shape.
///
/// Config passed by value (cheap clone) so the caller can spawn
/// this on a background thread without keeping `&App` alive.
pub fn trigger_run(config: CloudAgentsConfig, jira: JiraConfig, ticket: &str) -> TriggerResult {
    if !config.is_enabled() {
        return TriggerResult::Err("cloud_agents config not set — nothing to trigger".to_string());
    }
    let ticket = ticket.trim().to_string();
    let prefix = jira.effective_ticket_prefix();
    if !is_valid_ticket(&ticket, prefix.as_deref()) {
        let expected = prefix
            .as_deref()
            .map(|p| format!("{p}NNNN"))
            .unwrap_or_else(|| "PROJ-NNNN".to_string());
        return TriggerResult::Err(format!("invalid ticket `{ticket}` — expected {expected}"));
    }
    let region = config.effective_region();
    let cluster = &config.cluster;
    let task_definition = &config.task_definition;
    let runs_table = &config.runs_table;
    let sg_export_name = &config.sg_export_name;
    if cluster.is_empty() || task_definition.is_empty() || sg_export_name.is_empty() {
        return TriggerResult::Err(
            "cloud_agents config incomplete — need cluster, task_definition, sg_export_name"
                .to_string(),
        );
    }
    let env = "prod";
    let flow = "triage";
    let now_unix = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let run_id = format!("{ticket}-{env}-mnml-{now_unix}");
    let command_line = format!("/triage-auto {ticket} --env={env}");

    // 1. Discover network config.
    let subnets = match run_capture(&[
        "ec2",
        "describe-subnets",
        "--region",
        &region,
        "--filters",
        "Name=tag:Tier,Values=Private",
        "--query",
        "Subnets[*].SubnetId",
        "--output",
        "text",
    ]) {
        Ok(s) => s.trim().replace('\t', ",").replace(['\n'], ","),
        Err(e) => return TriggerResult::Err(format!("describe-subnets: {e}")),
    };
    if subnets.is_empty() {
        return TriggerResult::Err("couldn't resolve private subnets — check VPC tags".to_string());
    }
    let security_group = match run_capture(&[
        "cloudformation",
        "list-exports",
        "--region",
        &region,
        "--query",
        &format!("Exports[?Name=='{sg_export_name}'].Value"),
        "--output",
        "text",
    ]) {
        Ok(s) => s.trim().to_string(),
        Err(e) => return TriggerResult::Err(format!("list-exports: {e}")),
    };
    if security_group.is_empty() {
        return TriggerResult::Err(format!("couldn't resolve CFN export `{sg_export_name}`"));
    }

    // 2. Fire ecs:RunTask. The overrides JSON pushes the bash env
    // variables the runner container's entrypoint reads
    // (`RUN_ID`, `TICKET`, `FLOW`, `CLAUDE_COMMAND`).
    let overrides = format!(
        r#"{{"containerOverrides":[{{"name":"claude-runner","environment":[{{"name":"CLAUDE_COMMAND","value":"{command_line}"}},{{"name":"RUN_ID","value":"{run_id}"}},{{"name":"TICKET","value":"{ticket}"}},{{"name":"FLOW","value":"{flow}"}}]}}]}}"#
    );
    let network = format!(
        "awsvpcConfiguration={{subnets=[{subnets}],securityGroups=[{security_group}],assignPublicIp=DISABLED}}"
    );
    let task_arn = match run_capture(&[
        "ecs",
        "run-task",
        "--region",
        &region,
        "--cluster",
        cluster,
        "--task-definition",
        task_definition,
        "--launch-type",
        "FARGATE",
        "--network-configuration",
        &network,
        "--overrides",
        &overrides,
        "--query",
        "tasks[0].taskArn",
        "--output",
        "text",
    ]) {
        Ok(s) => s.trim().to_string(),
        Err(e) => return TriggerResult::Err(format!("ecs run-task: {e}")),
    };
    if task_arn.is_empty() || task_arn == "None" {
        return TriggerResult::Err("ecs run-task returned no taskArn".to_string());
    }

    // 3. Seed the DynamoDB row so the Cloud Agents panel picks up
    // the new run on its next refresh (~30s). The container writes
    // its own row on startup, but seeding here means immediate
    // feedback in mnml.
    let created_at = iso_now();
    let ttl = now_unix as i64 + 30 * 24 * 3600;
    let item = format!(
        r#"{{"runId":{{"S":"{run_id}"}},"ticket":{{"S":"{ticket}"}},"flow":{{"S":"{flow}"}},"source":{{"S":"manual"}},"state":{{"S":"started"}},"createdAt":{{"S":"{created_at}"}},"ttl":{{"N":"{ttl}"}}}}"#
    );
    if let Err(e) = run_capture(&[
        "dynamodb",
        "put-item",
        "--region",
        &region,
        "--table-name",
        runs_table,
        "--item",
        &item,
    ]) {
        return TriggerResult::Ok {
            run_id: format!("{run_id} (seed failed: {e})"),
            task_arn,
        };
    }

    TriggerResult::Ok { run_id, task_arn }
}

fn run_capture(args: &[&str]) -> Result<String, String> {
    let out = Command::new("aws")
        .args(args)
        .output()
        .map_err(|e| format!("spawn aws: {e}"))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(stderr.trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Validate a ticket id. Shape: `[A-Z]+-\d+`. If `prefix` is
/// supplied, additionally require the ticket start with that
/// exact prefix.
pub(crate) fn is_valid_ticket(t: &str, prefix: Option<&str>) -> bool {
    let dash_idx = match t.find('-') {
        Some(i) if i > 0 => i,
        _ => return false,
    };
    let (head, tail_incl_dash) = t.split_at(dash_idx);
    let tail = &tail_incl_dash[1..];
    if tail.is_empty() {
        return false;
    }
    if !head.chars().all(|c| c.is_ascii_uppercase()) {
        return false;
    }
    if !tail.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    if let Some(p) = prefix
        && !t.starts_with(p)
    {
        return false;
    }
    true
}

fn iso_now() -> String {
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    let (y, mo, d, h, mi, s) = epoch_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.000Z")
}

fn epoch_to_ymdhms(epoch: i64) -> (i32, u32, u32, u32, u32, u32) {
    let z = epoch.div_euclid(86_400) + 719_468;
    let secs_of_day = epoch.rem_euclid(86_400);
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i32 + era as i32 * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let h = (secs_of_day / 3600) as u32;
    let mi = ((secs_of_day % 3600) / 60) as u32;
    let s = (secs_of_day % 60) as u32;
    (y, m, d, h, mi, s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_valid_ticket_shape_without_prefix() {
        assert!(is_valid_ticket("TE-1234", None));
        assert!(is_valid_ticket("PROJ-42", None));
        assert!(!is_valid_ticket("TE-12X4", None));
        assert!(!is_valid_ticket("TE-", None));
        assert!(!is_valid_ticket("te-1234", None));
        assert!(!is_valid_ticket("1234-TE", None));
    }

    #[test]
    fn enforces_prefix_when_supplied() {
        assert!(is_valid_ticket("TE-1234", Some("TE-")));
        assert!(!is_valid_ticket("FE-1234", Some("TE-")));
        assert!(!is_valid_ticket("PROJ-1234", Some("TE-")));
    }

    #[test]
    fn rejects_when_config_disabled() {
        let r = trigger_run(
            CloudAgentsConfig::default(),
            JiraConfig::default(),
            "TE-1234",
        );
        match r {
            TriggerResult::Err(e) => assert!(e.contains("not set")),
            _ => panic!("expected Err"),
        }
    }
}
