{ config, pkgs, lib, ... }:

let
  # Central app database registry.
  # Add one entry per app. Each gets a dedicated database + user.
  appDatabases = [
    { name = "family-archive"; user = "family_archive"; dbName = "family_archive"; }
    { name = "home-cooking"; user = "home_cooking"; dbName = "home_cooking"; }
    { name = "healthchecks"; user = "healthchecks"; dbName = "healthchecks"; }
    { name = "lupin-api-production"; user = "lupin_production"; dbName = "lupin_production"; }
    { name = "lupin-api-staging"; user = "lupin_staging"; dbName = "lupin_staging"; }
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

  # Set database passwords from sops secrets and configure PgBouncer auth_query.
  # Adding a new app only requires:
  #   1. Add entry to appDatabases above
  #   2. Add <app-name>/database-password to sops secrets
  #   3. Rebuild — PgBouncer resolves new users dynamically via auth_query
  systemd.services.db-passwords = {
    description = "Set database passwords and configure PgBouncer auth";
    after = [ "postgresql.service" "sops-nix.service" ];
    requires = [ "postgresql.service" ];
    before = [ "pgbouncer-auth.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = let
        psql = "${config.services.postgresql.package}/bin/psql";
      in pkgs.writeShellScript "db-passwords" ''
        # Set app passwords
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
          EXPORTER_PASS="$(echo "$EXPORTER_DSN" | ${pkgs.gnused}/bin/sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')"
          if [ -n "$EXPORTER_PASS" ]; then
            ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "ALTER USER postgres_exporter WITH PASSWORD '$EXPORTER_PASS';" 2>/dev/null
            ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "GRANT pg_monitor TO postgres_exporter;" 2>/dev/null
            echo "Set password for postgres_exporter"
          fi
        fi

        # PgBouncer lookup user + auth_query function
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

          # SECURITY DEFINER function runs as postgres (superuser), so the
          # pgbouncer user doesn't need direct access to pg_shadow.
          ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "
            CREATE OR REPLACE FUNCTION public.pgbouncer_get_auth(p_usename TEXT)
            RETURNS TABLE(usename name, passwd text) AS
            \$\$
              SELECT usename, passwd FROM pg_shadow WHERE usename = p_usename;
            \$\$
            LANGUAGE sql SECURITY DEFINER STABLE;
          " 2>/dev/null

          ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "REVOKE ALL ON FUNCTION public.pgbouncer_get_auth(TEXT) FROM PUBLIC;" 2>/dev/null
          ${pkgs.sudo}/bin/sudo -u postgres ${psql} -c "GRANT EXECUTE ON FUNCTION public.pgbouncer_get_auth(TEXT) TO pgbouncer;" 2>/dev/null
          echo "Configured pgbouncer auth_query user and function"
        fi
      '';
    };
  };

  # Write the pgbouncer lookup user's plaintext password to the auth file.
  # Only this one user is in the file — all app users are resolved via auth_query.
  systemd.services.pgbouncer-auth = {
    description = "Generate PgBouncer auth file for lookup user";
    after = [ "db-passwords.service" "sops-nix.service" ];
    requires = [ "db-passwords.service" ];
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
        auth_dbname = "postgres";
        auth_query = "SELECT usename, passwd FROM public.pgbouncer_get_auth($1)";
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
