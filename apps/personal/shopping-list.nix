{ config, pkgs, lib, ... }:

let
  appName  = "shopping-list";
  domain   = "shopping-list.timothymarias.com";
  imageSha = builtins.replaceStrings ["\n"] [""] (builtins.readFile /var/lib/deploy/${appName}.sha);
  ghOrg    = "timothyjamesmarias";
  # Thruster fronts Puma inside the image and listens on 80.
  appPort  = "80";
  # Read by scripts/deploy.sh and health-check.sh; Rails' endpoint is /up.
  healthPath = "/up";
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${appName}@${imageSha}";

    environment = {
      RAILS_ENV = "production";
      TZ = "UTC";

      # Own hostname for Host-header authorization. The request host can't be
      # trusted behind Traefik.
      APP_HOST = domain;

      RAILS_MAX_THREADS = "3";
      WEB_CONCURRENCY = "1";
    };

    # Secrets injected as env vars from sops-decrypted file
    environmentFiles = [ "/run/${appName}/env" ];

    extraOptions = [
      "--network=proxy-net"
      "--add-host=host.docker.internal:host-gateway"
    ];

    labels = {
      "traefik.enable" = "true";
      "traefik.http.routers.${appName}.rule" = "Host(`${domain}`)";
      "traefik.http.routers.${appName}.entrypoints" = "websecure";
      "traefik.http.routers.${appName}.tls" = "true";
      "traefik.http.routers.${appName}.middlewares" = "rate-limit@file,secure-headers@file";
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
        DB_PASS="$(cat ${config.sops.secrets."shopping-list/database-password".path})"
        {
          # Rails merges DATABASE_URL over config/database.yml. Goes through
          # PgBouncer (transaction pooling); the app disables advisory locks
          # and prepared statements accordingly.
          echo "DATABASE_URL=postgres://shopping_list:''${DB_PASS}@host.docker.internal:6432/shopping_list?sslmode=disable"
          echo "SECRET_KEY_BASE=$(cat ${config.sops.secrets."shopping-list/secret-key-base".path})"
          echo "ADMIN_EMAIL=$(cat ${config.sops.secrets."shopping-list/admin-email".path})"
          echo "ADMIN_PASSWORD=$(cat ${config.sops.secrets."shopping-list/admin-password".path})"
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
