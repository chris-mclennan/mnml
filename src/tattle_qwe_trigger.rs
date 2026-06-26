//! Trigger a Tattle qwe-runner cloud run from inside mnml. Mirrors
//! the shell shape `qwe-runner/scripts/smoke.sh` uses: discover
//! network config from CFN exports + EC2 tags, fire `aws ecs
//! run-task`, then seed the DynamoDB `qwe-runner-runs` row so the
//! cloud-agents panel picks it up on the next refresh.
//!
//! Shelling out to the AWS CLI matches the rest of `tattle_qwe.rs`
//! and dodges ~50 transitive deps from `aws-sdk-*` crates. The
//! discovery calls are cacheable but for v1 we re-resolve each
//! trigger (cheap; both calls are <100ms).
//!
//! Auth: caller is expected to have an SSO profile (typically
//! `default` mapped to the Developer SSO role) with
//! `ecs:RunTask` + `iam:PassRole` + `dynamodb:PutItem` granted.
//! Errors surface via the toast channel.

use std::process::Command;
use std::time::SystemTime;

const REGION: &str = "us-east-1";
const CLUSTER: &str = "qwe-runner";
const TASK_DEFINITION: &str = "qwe-runner-claude-runner";
const RUNS_TABLE: &str = "qwe-runner-runs";
const SG_EXPORT_NAME: &str = "QweRunnerEcsSecurityGroupId";

/// Outcome of `trigger_run` reported back to App via the worker
/// channel.
#[derive(Debug)]
pub enum TriggerResult {
    Ok { run_id: String, task_arn: String },
    Err(String),
}

/// Fire a qwe-runner cloud run for `ticket`. Default flow is
/// `triage`, env `prod` — the most common case. The full
/// `command` line passed to the container is `/triage-auto
/// <ticket> --env=prod`, mirroring smoke.sh's default.
pub fn trigger_run(ticket: &str) -> TriggerResult {
    let ticket = ticket.trim().to_string();
    if !is_valid_ticket(&ticket) {
        return TriggerResult::Err(format!("invalid ticket `{ticket}` — expected TE-NNNN"));
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
        REGION,
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
        REGION,
        "--query",
        &format!("Exports[?Name=='{SG_EXPORT_NAME}'].Value"),
        "--output",
        "text",
    ]) {
        Ok(s) => s.trim().to_string(),
        Err(e) => return TriggerResult::Err(format!("list-exports: {e}")),
    };
    if security_group.is_empty() {
        return TriggerResult::Err(format!("couldn't resolve CFN export `{SG_EXPORT_NAME}`"));
    }

    // 2. Fire ecs:RunTask. The overrides JSON pushes the bash env
    // variables qwe-runner's entrypoint reads (`RUN_ID`, `TICKET`,
    // `FLOW`, `CLAUDE_COMMAND`).
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
        REGION,
        "--cluster",
        CLUSTER,
        "--task-definition",
        TASK_DEFINITION,
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
    // the new run on its next refresh (~30s). qwe-runner's
    // container would write its own row on startup, but seeding
    // here means the user gets immediate feedback in mnml.
    let created_at = iso_now();
    let ttl = now_unix as i64 + 30 * 24 * 3600; // matches qwe-runner's 30d TTL
    let item = format!(
        r#"{{"runId":{{"S":"{run_id}"}},"ticket":{{"S":"{ticket}"}},"flow":{{"S":"{flow}"}},"source":{{"S":"manual"}},"state":{{"S":"started"}},"createdAt":{{"S":"{created_at}"}},"ttl":{{"N":"{ttl}"}}}}"#
    );
    if let Err(e) = run_capture(&[
        "dynamodb",
        "put-item",
        "--region",
        REGION,
        "--table-name",
        RUNS_TABLE,
        "--item",
        &item,
    ]) {
        // Soft failure: the container will create the row on its
        // own. Surface the warning but the run did fire.
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

fn is_valid_ticket(t: &str) -> bool {
    // qwe-runner expects `TE-` + digits.
    t.len() > 3 && t.starts_with("TE-") && t[3..].chars().all(|c| c.is_ascii_digit())
}

fn iso_now() -> String {
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    let (y, mo, d, h, mi, s) = epoch_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.000Z")
}

/// Lifted from `tattle_qwe.rs` to avoid cross-module exports for
/// a 5-line helper. Stays a self-contained module.
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
    fn rejects_bad_ticket() {
        let r = trigger_run("BAD");
        match r {
            TriggerResult::Err(e) => assert!(e.contains("invalid ticket")),
            _ => panic!("expected Err"),
        }
    }

    #[test]
    fn accepts_valid_ticket_shape() {
        assert!(is_valid_ticket("TE-1234"));
        assert!(!is_valid_ticket("TE-12X4"));
        assert!(!is_valid_ticket("TE-"));
        assert!(!is_valid_ticket("FE-1234"));
    }
}
