{ config, pkgs, lib, ... }:

let
  appName  = "family-archive";
  domain   = "mariasfamilyarchive.com";
  imageSha = builtins.replaceStrings ["\n"] [""] (builtins.readFile /var/lib/deploy/${appName}.sha);
  ghOrg    = "timothyjamesmarias";
  # Thruster fronts Puma inside the image and listens on 80.
  appPort  = "80";
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${appName}@${imageSha}";

    environment = {
      RAILS_ENV = "production";
      TZ = "UTC";

      # Own hostname: mailer URLs and Host-header authorization. The request
      # host can't be trusted behind Traefik.
      APP_HOST = domain;

      RAILS_MAX_THREADS = "3";
      WEB_CONCURRENCY = "2";

      # Solid Queue runs inside Puma; its tables (and Solid Cache/Cable) live
      # in SQLite files under /rails/storage, not in Postgres. Replace with
      # Sidekiq on the redis queue instance later (docs/FAMILY-ARCHIVE-CUTOVER.md).
      SOLID_QUEUE_IN_PUMA = "true";
      JOB_CONCURRENCY = "1";

      # Folder inside the bucket that new blob keys are generated under.
      # Existing keys are stored in the DB, so changing this only affects uploads.
      AWS_S3_KEY_PREFIX = "production";
    };

    # Secrets injected as env vars from sops-decrypted file
    environmentFiles = [ "/run/${appName}/env" ];

    # SQLite databases for the Solid stack. Ephemeral by nature (cache entries,
    # queued jobs, cable messages), so not backed up — but they must outlive a
    # container restart or in-flight jobs vanish.
    volumes = [ "${appName}-storage:/rails/storage" ];

    extraOptions = [
      "--network=proxy-net"
      "--add-host=host.docker.internal:host-gateway"
    ];

    labels = {
      "traefik.enable" = "true";
      "traefik.http.routers.${appName}.rule" = "Host(`${domain}`)";
      "traefik.http.routers.${appName}.entrypoints" = "websecure";
      "traefik.http.routers.${appName}.tls" = "true";
      "traefik.http.routers.${appName}.middlewares" = "rate-limit@file,secure-headers-family-archive@file";
      "traefik.http.services.${appName}.loadbalancer.server.port" = appPort;
    };

    dependsOn = [ "traefik" ];
  };

  # Generate env file from sops secrets
  systemd.services."${appName}-env" = {
    description = "Generate ${appName} environment file from secrets";
    after = [ "sops-nix.service" ];
    before = [ "docker-${appName}.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "${appName}-env" ''
        mkdir -p /run/${appName}
        DB_PASS="$(cat ${config.sops.secrets."family-archive/database-password".path})"
        {
          # Rails merges DATABASE_URL over config/database.yml. Goes through
          # PgBouncer (transaction pooling); the app disables advisory locks
          # and prepared statements accordingly.
          echo "DATABASE_URL=postgres://family_archive:''${DB_PASS}@host.docker.internal:6432/family_archive?sslmode=disable"
          echo "SECRET_KEY_BASE=$(cat ${config.sops.secrets."family-archive/secret-key-base".path})"
          echo "ADMIN_EMAIL=$(cat ${config.sops.secrets."family-archive/admin-email".path})"
          echo "ADMIN_PASSWORD=$(cat ${config.sops.secrets."family-archive/admin-password".path})"
          echo "ADMIN_NAME=$(cat ${config.sops.secrets."family-archive/admin-name".path})"
          echo "AWS_S3_BUCKET=$(cat ${config.sops.secrets."family-archive/s3-bucket".path})"
          echo "AWS_REGION=$(cat ${config.sops.secrets."family-archive/s3-region".path})"
          echo "AWS_ACCESS_KEY_ID=$(cat ${config.sops.secrets."family-archive/aws-access-key-id".path})"
          echo "AWS_SECRET_ACCESS_KEY=$(cat ${config.sops.secrets."family-archive/aws-secret-access-key".path})"
        } > /run/${appName}/env
        chmod 600 /run/${appName}/env
      '';
    };
  };

  # Ensure the container starts after the proxy network exists
  systemd.services."docker-${appName}" = {
    after = [
      "docker-network-proxy-net.service"
      "${appName}-env.service"
      "pgbouncer.service"
    ];
    requires = [
      "docker-network-proxy-net.service"
    ];
    bindsTo = [
      "${appName}-env.service"
    ];
    serviceConfig = {
      RestartSec = "5s";
      StartLimitBurst = 10;
      StartLimitIntervalSec = "120s";
    };
  };
}
