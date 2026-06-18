{ config, pkgs, lib, ... }:

let
  # Central app database registry.
  # Add one entry per app. Each gets a dedicated database + user.
  appDatabases = [
    { name = "family-archive"; user = "family_archive"; dbName = "family_archive"; }
    { name = "home-cooking"; user = "home_cooking"; dbName = "home_cooking"; }
    { name = "healthchecks"; user = "healthchecks"; dbName = "healthchecks"; }
  ];

  # Docker bridge subnet — containers connect from this range.
  # Verify with: docker network inspect postgres-net | jq '.[0].IPAM.Config[0].Subnet'
  dockerSubnet = "172.18.0.0/16"; # TODO: verify after network creation
in
{
  # --- PostgreSQL ---

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    settings = {
      # Connection limits — PgBouncer sits in front, so this handles pooled connections
      max_connections = 100;

      # Memory — tune based on available RAM
      # TODO: adjust for your hardware (general rule: shared_buffers = 25% of RAM)
      shared_buffers = "256MB";
      effective_cache_size = "768MB";
      work_mem = "4MB";
      maintenance_work_mem = "128MB";

      # WAL
      wal_buffers = "8MB";

      # Logging
      log_min_duration_statement = 1000; # log queries > 1s
    };

    ensureDatabases = map (app: app.dbName) appDatabases;

    ensureUsers = (map (app: {
      name = app.user;
      ensureDBOwnership = true;
    }) appDatabases) ++ [
      { name = "postgres_exporter"; }
    ];

    # Per-app authentication: each user can only connect to its own database
    authentication = lib.mkForce (
      ''
        # Local connections (backups, admin)
        local all      postgres                peer

        local all      all                     peer

        # PgBouncer connects via localhost
        host  all      all      127.0.0.1/32   scram-sha-256

        # Per-app rules — Docker containers connect from the bridge subnet
      ''
      + lib.concatMapStringsSep "\n" (app:
        "host  ${app.dbName}  ${app.user}  ${dockerSubnet}  scram-sha-256"
      ) appDatabases
      + ''

        # Postgres exporter (monitoring)
        host  postgres  postgres_exporter  127.0.0.1/32  scram-sha-256
      ''
    );
  };

  # Set database passwords from sops secrets.
  # Adding a new app only requires:
  #   1. Add entry to appDatabases above
  #   2. Add <app-name>/database-password to sops secrets
  #   3. Rebuild — passwords are set automatically, PgBouncer resolves them via auth_query
  systemd.services.db-passwords = {
    description = "Set database passwords from sops secrets";
    after = [ "postgresql.service" "sops-nix.service" ];
    requires = [ "postgresql.service" ];
    before = [ "pgbouncer.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = let
        psql = "${config.services.postgresql.package}/bin/psql";
      in pkgs.writeShellScript "db-passwords" ''
        ${lib.concatMapStringsSep "\n" (app: ''
          PASS="$(cat ${config.sops.secrets."${app.name}/database-password".path} 2>/dev/null || true)"
          if [ -n "$PASS" ]; then
            ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "ALTER USER ${app.user} WITH PASSWORD '$PASS';" 2>/dev/null
            echo "Set password for ${app.user}"
          fi
        '') appDatabases}

        # Postgres exporter monitoring user
        EXPORTER_DSN="$(cat ${config.sops.secrets."postgres-exporter-dsn".path} 2>/dev/null || true)"
        if [ -n "$EXPORTER_DSN" ]; then
          # Extract password from DSN (format: postgresql://user:pass@host:port/db)
          EXPORTER_PASS="$(echo "$EXPORTER_DSN" | ${pkgs.gnused}/bin/sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')"
          if [ -n "$EXPORTER_PASS" ]; then
            ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "ALTER USER postgres_exporter WITH PASSWORD '$EXPORTER_PASS';" 2>/dev/null
            ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "GRANT pg_monitor TO postgres_exporter;" 2>/dev/null
            echo "Set password for postgres_exporter"
          fi
        fi

        # PgBouncer lookup user — needs pg_shadow access for auth_query
        PGB_PASS="$(cat ${config.sops.secrets."pgbouncer/lookup-password".path} 2>/dev/null || true)"
        if [ -n "$PGB_PASS" ]; then
          ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "
            DO \$\$
            BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer') THEN
                CREATE USER pgbouncer WITH PASSWORD '$PGB_PASS';
              ELSE
                ALTER USER pgbouncer WITH PASSWORD '$PGB_PASS';
              END IF;
            END
            \$\$;
          " 2>/dev/null
          ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "GRANT SELECT ON pg_shadow TO pgbouncer;" 2>/dev/null
          echo "Set password for pgbouncer lookup user"
        fi
      '';
    };
  };

  # Write the pgbouncer lookup user's plaintext password to the auth file.
  # Must be plaintext (not SCRAM hash) so PgBouncer can authenticate to Postgres for auth_query.
  # All app users are resolved dynamically via auth_query — no regeneration needed.
  systemd.services.pgbouncer-auth = {
    description = "Generate PgBouncer auth file for lookup user";
    after = [ "sops-nix.service" ];
    before = [ "pgbouncer.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "pgbouncer-auth";
      RuntimeDirectoryMode = "0755";
      ExecStart = pkgs.writeShellScript "pgbouncer-auth" ''
        PGB_PASS="$(cat ${config.sops.secrets."pgbouncer/lookup-password".path})"
        echo "\"pgbouncer\" \"$PGB_PASS\"" > /run/pgbouncer-auth/userlist.txt
        chmod 640 /run/pgbouncer-auth/userlist.txt
        chgrp pgbouncer /run/pgbouncer-auth/userlist.txt
      '';
    };
  };

  # --- PgBouncer ---

  # PgBouncer must start after Docker so the docker0 bridge (172.17.0.1) exists
  systemd.services.pgbouncer = {
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
  };

  services.pgbouncer = {
    enable = true;

    settings = {
      pgbouncer = {
        pool_mode = "transaction";
        max_client_conn = 400;
        default_pool_size = 20;
        min_pool_size = 5;

        listen_addr = "127.0.0.1,172.17.0.1";
        listen_port = 6432;

        auth_type = "scram-sha-256";
        auth_file = "/run/pgbouncer-auth/userlist.txt";
        auth_user = "pgbouncer";
        auth_query = "SELECT usename, passwd FROM pg_shadow WHERE usename=$1";
        ignore_startup_parameters = "extra_float_digits";
      };

      databases = lib.listToAttrs ((map (app: {
        name = app.dbName;
        value = "host=127.0.0.1 port=5432 dbname=${app.dbName}";
      }) appDatabases) ++ [
        { name = "postgres"; value = "host=127.0.0.1 port=5432 dbname=postgres"; }
      ]);
    };
  };

}
