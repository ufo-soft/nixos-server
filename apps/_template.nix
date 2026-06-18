# ============================================================================
# App Template — copy this file and fill in the TODOs.
#
# Checklist for adding a new app:
#   1. Copy this file to apps/<your-app>.nix
#   2. Fill in appName, domain, and GitHub org below
#   3. Add environment variables and secrets (see comments below)
#   4. Add a database entry to modules/postgresql.nix (appDatabases list):
#        { name = "my-app"; user = "my_app"; dbName = "my_app"; }
#   5. Add app secrets to secrets/secrets.yaml (and declare them in modules/secrets.nix):
#        - my-app/database-password (required — set automatically on rebuild)
#   6. Import the new file in configuration.nix
#   7. Create the initial SHA file on the server:
#        sudo mkdir -p /var/lib/deploy
#        echo -n "sha256:<digest>" | sudo tee /var/lib/deploy/my-app.sha
#   8. Deploy: nixos-rebuild switch --flake ~/nixos-server#server
#
# Image SHAs are stored in /var/lib/deploy/<app-name>.sha on the server,
# updated by the deploy script. They are not tracked in git.
#
# Database passwords are set automatically from sops secrets on every rebuild.
# No manual psql or PgBouncer restarts needed.
#
# Domain notes:
#   - Each app can use any domain or subdomain you control.
#   - Every domain must have DNS managed through Cloudflare.
#   - For new domains (not subdomains of timothymarias.com):
#       * Add zone + A record in Cloudflare
#       * Generate Origin CA cert, add to sops secrets
#       * Add cert to traefik.nix tls.certificates + traefik-env service
#       * Ensure Cloudflare API token covers the new zone
# ============================================================================
{ config, pkgs, lib, ... }:

let
  appName  = "my-app";       # TODO: container and router name (kebab-case)
  domain   = "my-app.example.com"; # TODO: any domain/subdomain you control
  imageSha = builtins.replaceStrings ["\n"] [""] (builtins.readFile /var/lib/deploy/${appName}.sha);
  ghOrg    = "timothyjamesmarias";
  appPort  = "8080";         # Port the app listens on inside the container
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${appName}@${imageSha}";

    environment = {
      # OpenTelemetry — send traces/metrics to the OTel Collector
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector:4317";
      OTEL_SERVICE_NAME = appName;

      # App-specific non-secret environment variables go here
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
      # Pick the right middleware combo:
      #   - secure-headers@file — standard, X-Frame-Options: DENY
      #   - secure-headers-sameorigin@file — allows iframes (for TinyMCE, etc.)
      #   - forward-auth@file — delegates auth to an external service (not yet deployed)
      "traefik.http.routers.${appName}.middlewares" = "rate-limit@file,secure-headers@file";
      "traefik.http.services.${appName}.loadbalancer.server.port" = appPort;
    };

    dependsOn = [ "traefik" ];
  };

  # Generate env file from sops secrets.
  # Adapt the echo lines below for your app's secrets.
  # For the DATABASE_URL, use the format your app expects:
  #   Go (pgx):    postgres://user:pass@host:6432/db?sslmode=disable
  #   Kotlin/JVM:  jdbc:postgresql://host:6432/db  (user/pass separate)
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
        DB_PASS="$(cat ${config.sops.secrets."${appName}/database-password".path})"
        {
          echo "DATABASE_URL=postgres://${lib.replaceStrings ["-"] ["_"] appName}:''${DB_PASS}@host.docker.internal:6432/${lib.replaceStrings ["-"] ["_"] appName}?sslmode=disable"
          # Add more secrets here:
          # echo "SECRET_KEY=$(cat ${config.sops.secrets."${appName}/secret-key".path})"
        } > /run/${appName}/env
        chmod 600 /run/${appName}/env
      '';
    };
  };

  # Scheduled jobs — uncomment and customise as needed.
  # See modules/cron.nix for full option reference.
  # services.appCronJobs = [
  #   {
  #     app = appName;
  #     name = "cleanup";
  #     schedule = "*-*-* 02:00:00";    # daily at 2 AM
  #     type = "http";                  # or "exec"
  #     endpoint = "http://${appName}:${appPort}/api/cron/cleanup";
  #     pingUrl = "http://healthchecks:8000/ping/<uuid>";  # from Healthchecks UI
  #     description = "Nightly data cleanup";
  #   }
  #   {
  #     app = appName;
  #     name = "send-digests";
  #     schedule = "*-*-* 08:00:00";
  #     type = "exec";
  #     command = "/app/bin/send-digests";
  #     pingUrl = "http://healthchecks:8000/ping/<uuid>";
  #     description = "Send daily email digests";
  #   }
  # ];

  # Ensure the container starts after the proxy network and env file exist
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
      # Survive transient PgBouncer/network blips on boot
      RestartSec = "5s";
      StartLimitBurst = 10;
      StartLimitIntervalSec = "120s";
    };
  };
}
