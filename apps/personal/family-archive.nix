{ config, pkgs, lib, ... }:

let
  appName  = "family-archive";
  domain   = "mariasfamilyarchive.com";
  imageSha = builtins.replaceStrings ["\n"] [""] (builtins.readFile /var/lib/deploy/${appName}.sha);
  ghOrg    = "timothyjamesmarias";
  appPort  = "8080";
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${appName}@${imageSha}";

    environment = {
      # Storage — S3 for images (credentials in env file)
      STORAGE_TYPE = "s3";

      # OpenTelemetry
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector:4317";
      OTEL_SERVICE_NAME = appName;
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
      "traefik.http.routers.${appName}.middlewares" = "rate-limit@file,secure-headers-sameorigin@file";
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
          echo "DATABASE_URL=postgres://family_archive:''${DB_PASS}@host.docker.internal:6432/family_archive?sslmode=disable"
          echo "SESSION_SECRET=$(cat ${config.sops.secrets."family-archive/session-secret".path})"
          echo "ADMIN_EMAIL=$(cat ${config.sops.secrets."family-archive/admin-email".path})"
          echo "ADMIN_PASSWORD=$(cat ${config.sops.secrets."family-archive/admin-password".path})"
          echo "S3_BUCKET=$(cat ${config.sops.secrets."family-archive/s3-bucket".path})"
          echo "S3_REGION=$(cat ${config.sops.secrets."family-archive/s3-region".path})"
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
