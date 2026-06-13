#!/usr/bin/env bash
# ============================================================================
# cron.sh — List and manage app cron jobs (systemd timers).
#
# Usage:
#   ./scripts/cron.sh                  # list all app cron timers
#   ./scripts/cron.sh status           # list with next/last run times
#   ./scripts/cron.sh logs <app> <job> # show recent logs for a job
#   ./scripts/cron.sh run  <app> <job> # trigger a job immediately
# ============================================================================
set -euo pipefail

CMD="${1:-list}"

case "$CMD" in
  list)
    echo "App cron timers:"
    echo "──────────────────────────────────────────────"
    systemctl list-timers 'cron-*' --no-pager
    ;;

  status)
    echo "App cron timer status:"
    echo "──────────────────────────────────────────────"
    systemctl list-timers 'cron-*' --all --no-pager
    ;;

  logs)
    APP="${2:?Usage: cron.sh logs <app> <job>}"
    JOB="${3:?Usage: cron.sh logs <app> <job>}"
    journalctl -u "cron-${APP}-${JOB}.service" --no-pager -n 50
    ;;

  run)
    APP="${2:?Usage: cron.sh run <app> <job>}"
    JOB="${3:?Usage: cron.sh run <app> <job>}"
    echo "Triggering cron-${APP}-${JOB}..."
    sudo systemctl start "cron-${APP}-${JOB}.service"
    echo "Done. Check logs with: ./scripts/cron.sh logs ${APP} ${JOB}"
    ;;

  *)
    echo "Unknown command: $CMD"
    echo "Usage: cron.sh [list|status|logs|run] [<app> <job>]"
    exit 1
    ;;
esac
