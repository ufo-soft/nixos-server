# ============================================================================
# App Cron Jobs — declarative scheduled tasks for app containers.
#
# Apps register jobs by appending to `services.appCronJobs`. Each job becomes
# a systemd oneshot service + timer pair named `cron-<app>-<name>`.
#
# Two job types:
#   - "http"  — curl an endpoint on the app container (via Traefik or direct)
#   - "exec"  — docker exec a command inside the running container
#
# Heartbeat monitoring:
#   Set `pingUrl` to a Healthchecks.io ping URL and the job will automatically
#   signal start, success, and failure. Get the URL from the Healthchecks UI
#   after creating a check.
#
# Usage in an app file:
#
#   services.appCronJobs = [
#     {
#       app = "my-app";
#       name = "cleanup";
#       schedule = "*-*-* 02:00:00";   # systemd OnCalendar syntax
#       type = "http";
#       endpoint = "http://my-app:8080/api/cron/cleanup";
#       pingUrl = "http://healthchecks:8000/ping/<uuid>";
#       description = "Nightly data cleanup";
#     }
#     {
#       app = "my-app";
#       name = "send-digests";
#       schedule = "*-*-* 08:00:00";
#       type = "exec";
#       command = "/app/bin/send-digests";
#       pingUrl = "http://healthchecks:8000/ping/<uuid>";
#       description = "Send daily email digests";
#     }
#   ];
# ============================================================================
{ config, pkgs, lib, ... }:

let
  cfg = config.services.appCronJobs;

  jobType = lib.types.submodule {
    options = {
      app = lib.mkOption {
        type = lib.types.str;
        description = "App name (must match the container name)";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "Job name (kebab-case, unique per app)";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Human-readable description of what this job does";
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        description = "systemd OnCalendar expression (e.g. '*-*-* 02:00:00', 'hourly')";
      };
      type = lib.mkOption {
        type = lib.types.enum [ "http" "exec" ];
        description = "Job type: 'http' to curl an endpoint, 'exec' to docker exec a command";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "URL to curl (required when type = 'http')";
      };
      httpMethod = lib.mkOption {
        type = lib.types.str;
        default = "POST";
        description = "HTTP method for http-type jobs";
      };
      command = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Command to run inside the container (required when type = 'exec')";
      };
      persistent = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run missed jobs after downtime";
      };
      timeout = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Timeout in seconds before the job is killed";
      };
      pingUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Healthchecks ping URL for heartbeat monitoring (e.g. http://healthchecks:8000/ping/<uuid>)";
      };
    };
  };

  # Wrap the actual job command with Healthchecks ping signals
  mkJobScript = job:
    let
      curl = "${pkgs.curl}/bin/curl";
      hasPing = job.pingUrl != "";
      pingStart = lib.optionalString hasPing ''
        ${curl} -fsS -m 10 "${job.pingUrl}/start" -o /dev/null || true
      '';
      pingSuccess = lib.optionalString hasPing ''
        ${curl} -fsS -m 10 "${job.pingUrl}" -o /dev/null || true
      '';
      pingFail = lib.optionalString hasPing ''
        ${curl} -fsS -m 10 "${job.pingUrl}/fail" -o /dev/null || true
      '';
      trapAndPing = lib.optionalString hasPing ''
        ping_result() {
          local exit_code=$?
          if [ $exit_code -ne 0 ]; then
            ${pingFail}
          else
            ${pingSuccess}
          fi
        }
        trap ping_result EXIT
      '';
    in
    if job.type == "http" then
      pkgs.writeShellScript "cron-${job.app}-${job.name}" ''
        set -euo pipefail
        ${pingStart}
        ${trapAndPing}
        echo "Cron: ${job.app}/${job.name} — hitting ${job.endpoint}"
        RESPONSE=$(${curl} -sf -X ${job.httpMethod} \
          --max-time ${toString job.timeout} \
          -w "\n%{http_code}" \
          "${job.endpoint}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -1)
        BODY=$(echo "$RESPONSE" | sed '$d')
        echo "Response ($HTTP_CODE): $BODY"
        if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
          echo "ERROR: HTTP $HTTP_CODE"
          exit 1
        fi
      ''
    else
      pkgs.writeShellScript "cron-${job.app}-${job.name}" ''
        set -euo pipefail
        ${pingStart}
        ${trapAndPing}
        echo "Cron: ${job.app}/${job.name} — exec in container"
        ${pkgs.docker}/bin/docker exec ${job.app} ${job.command}
      '';

  mkJobService = job: {
    name = "cron-${job.app}-${job.name}";
    value = {
      description = "Cron: ${job.app}/${job.name}"
        + lib.optionalString (job.description != "") " — ${job.description}";
      after = [ "docker-${job.app}.service" ]
        ++ lib.optional (job.pingUrl != "") "docker-healthchecks.service";
      requires = [ "docker-${job.app}.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = mkJobScript job;
        TimeoutStartSec = "${toString job.timeout}s";
      };
    };
  };

  mkJobTimer = job: {
    name = "cron-${job.app}-${job.name}";
    value = {
      description = "Timer: ${job.app}/${job.name}"
        + lib.optionalString (job.description != "") " — ${job.description}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = job.schedule;
        Persistent = job.persistent;
      };
    };
  };

in
{
  options.services.appCronJobs = lib.mkOption {
    type = lib.types.listOf jobType;
    default = [];
    description = "Scheduled jobs for app containers";
  };

  config = lib.mkIf (cfg != []) {
    systemd.services = builtins.listToAttrs (map mkJobService cfg);
    systemd.timers = builtins.listToAttrs (map mkJobTimer cfg);
  };
}
