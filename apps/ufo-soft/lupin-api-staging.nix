{ config, pkgs, lib, ... }:

let
  appName   = "lupin-api-staging";
  domain    = "lupin-api-staging.timothymarias.com";
  imageSha  = builtins.replaceStrings ["\n"] [""] (builtins.readFile /var/lib/deploy/${appName}.sha);
  ghOrg     = "ufo-soft";
  imageName = "lupin-server";
  appPort   = "8080";
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${imageName}@${imageSha}";

    environment = {
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector:4317";
      OTEL_SERVICE_NAME = appName;
      # TODO: create check in Healthchecks and fill in UUID
      YTDLP_UPDATE_PING_URL = "http://healthchecks:8000/ping/2dfcecc6-cbe0-40a2-b5ef-5d14c48bf5d0";
    };

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
          echo "DATABASE_URL=jdbc:postgresql://host.docker.internal:6432/lupin_staging"
          echo "DATABASE_USER=lupin_staging"
          echo "DATABASE_PASSWORD=''${DB_PASS}"
        } > /run/${appName}/env
        chmod 600 /run/${appName}/env
      '';
    };
  };

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
