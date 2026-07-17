{ config, pkgs, lib, ... }:

let
  backupDir = "/var/backups";
  encKeyPath = config.sops.secrets."backup-encryption-key".path;

  # Databases to back up — derived from the registry in postgresql.nix.
  # Adding an app there backs it up automatically; there is no second list
  # to keep in sync. (This previously named only family_archive by hand,
  # which silently left every other app unbacked.)
  databases = map (app: app.dbName) config.appDatabases;

  pgBackupScript = pkgs.writeShellScript "pg-backup" ''
    set -euo pipefail
    DATE=$(date +%Y-%m-%d_%H%M%S)
    BACKUP_DIR="${backupDir}/postgresql"
    mkdir -p "$BACKUP_DIR"

    for DB in ${lib.concatStringsSep " " databases}; do
      echo "Backing up database: $DB"
      ${pkgs.postgresql_16}/bin/pg_dump -U postgres "$DB" \
        | ${pkgs.gzip}/bin/gzip \
        | ${pkgs.gnupg}/bin/gpg --symmetric --batch --yes --passphrase-file ${encKeyPath} \
          -o "$BACKUP_DIR/$DB-$DATE.sql.gz.gpg"
    done

    # Prune backups older than 30 days
    ${pkgs.findutils}/bin/find "$BACKUP_DIR" -name "*.sql.gz.gpg" -mtime +30 -delete
    echo "PostgreSQL backup complete"
  '';

  # Redis backup — QUEUE INSTANCE ONLY.
  #
  # The cache instance is deliberately not backed up: it runs with
  # `save []` and allkeys-lru, so everything in it is regenerable by
  # definition. Backing it up would archive data that is meant to be
  # disposable.
  #
  # The queue instance holds jobs, which are not regenerable — losing one
  # means work silently never happens. Hence BGSAVE + encrypt, on the same
  # daily schedule and with the same GPG key as the PostgreSQL backup.
  #
  # NOTE: redis-cli is authenticated as the default user via the unix socket.
  # BGSAVE is in the -@dangerous set that app ACL users are denied, so this
  # runs as the redis-queue system user rather than as any app.
  redisBackupScript = pkgs.writeShellScript "redis-backup" ''
    set -euo pipefail
    DATE=$(date +%Y-%m-%d_%H%M%S)
    BACKUP_DIR="${backupDir}/redis"
    DATA_DIR="/var/lib/redis-queue"
    mkdir -p "$BACKUP_DIR"

    echo "Triggering BGSAVE on redis-queue"

    # Record the last successful save time, trigger a new one, then wait for
    # it to change. Polling LASTSAVE is the documented way to know a BGSAVE
    # finished — BGSAVE itself returns immediately.
    LAST_SAVE=$(${pkgs.redis}/bin/redis-cli -p 6380 LASTSAVE)
    ${pkgs.redis}/bin/redis-cli -p 6380 BGSAVE

    WAITED=0
    while [ "$WAITED" -lt 60 ]; do
      CURRENT_SAVE=$(${pkgs.redis}/bin/redis-cli -p 6380 LASTSAVE)
      if [ "$CURRENT_SAVE" != "$LAST_SAVE" ]; then
        break
      fi
      sleep 1
      WAITED=$((WAITED + 1))
    done

    if [ "$WAITED" -ge 60 ]; then
      echo "BGSAVE did not complete within 60s — aborting rather than archiving a stale dump" >&2
      exit 1
    fi

    echo "BGSAVE complete, encrypting dump"
    ${pkgs.gnupg}/bin/gpg --symmetric --batch --yes --passphrase-file ${encKeyPath} \
      -o "$BACKUP_DIR/redis-queue-$DATE.rdb.gpg" "$DATA_DIR/dump.rdb"

    # Prune backups older than 30 days — matches the PostgreSQL retention.
    ${pkgs.findutils}/bin/find "$BACKUP_DIR" -name "*.rdb.gpg" -mtime +30 -delete
    echo "Redis queue backup complete"
  '';

  volumeBackupScript = pkgs.writeShellScript "volume-backup" ''
    set -euo pipefail
    DATE=$(date +%Y-%m-%d_%H%M%S)
    BACKUP_DIR="${backupDir}/volumes"
    mkdir -p "$BACKUP_DIR"

    # Back up all named Docker volumes
    for VOL in $(${pkgs.docker}/bin/docker volume ls -q); do
      echo "Backing up volume: $VOL"
      ${pkgs.docker}/bin/docker run --rm \
        -v "$VOL":/source:ro \
        -v "$BACKUP_DIR":/backup \
        alpine tar czf "/backup/$VOL-$DATE.tar.gz" -C /source .

      # Encrypt the backup
      ${pkgs.gnupg}/bin/gpg --symmetric --batch --yes --passphrase-file ${encKeyPath} \
        -o "$BACKUP_DIR/$VOL-$DATE.tar.gz.gpg" "$BACKUP_DIR/$VOL-$DATE.tar.gz"
      rm -f "$BACKUP_DIR/$VOL-$DATE.tar.gz"
    done

    # Prune volume backups older than 30 days
    ${pkgs.findutils}/bin/find "$BACKUP_DIR" -name "*.tar.gz.gpg" -mtime +30 -delete
    echo "Volume backup complete"
  '';
in
{
  # Daily PostgreSQL backup at 3 AM
  systemd.services.pg-backup = {
    description = "PostgreSQL database backup";
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      ExecStart = pgBackupScript;
    };
  };

  systemd.timers.pg-backup = {
    description = "Daily PostgreSQL backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true; # Run missed backups after downtime
    };
  };

  # Daily Redis queue backup at 3:30 AM — staggered after pg-backup so the
  # two are not competing for disk and CPU at the same instant.
  #
  # Runs as redis-queue (not root) so it can read the data dir and talk to
  # the instance without app ACL restrictions applying.
  systemd.services.redis-backup = {
    description = "Redis queue backup";
    after = [ "redis-queue.service" ];
    requires = [ "redis-queue.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "redis-queue";
      ExecStart = redisBackupScript;
    };
  };

  systemd.timers.redis-backup = {
    description = "Daily Redis queue backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
    };
  };

  # Weekly Docker volume backup at 4 AM Sunday
  systemd.services.volume-backup = {
    description = "Docker volume backup";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = volumeBackupScript;
    };
  };

  systemd.timers.volume-backup = {
    description = "Weekly Docker volume backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true;
    };
  };

  # TODO: Add offsite backup push (rsync/rclone to B2, S3, etc.)
  # Example systemd service that runs after pg-backup:
  # systemd.services.offsite-backup = {
  #   after = [ "pg-backup.service" ];
  #   serviceConfig.ExecStart = "${pkgs.rclone}/bin/rclone sync ${backupDir} remote:backups";
  # };
}
