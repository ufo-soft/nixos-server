{ config, pkgs, lib, ... }:

let
  appName  = "home-cooking";
  domain   = "home-cooking.timothymarias.com";
  imageSha = builtins.replaceStrings ["\n"] [""] (builtins.readFile /var/lib/deploy/${appName}.sha);
  ghOrg    = "timothyjamesmarias";
  appPort  = "8080";
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${appName}@${imageSha}";

    environment = {
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector:4317";
      OTEL_SERVICE_NAME = appName;
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
        DB_PASS="$(cat ${config.sops.secrets."home-cooking/database-password".path})"
        {
          echo "DATABASE_URL=postgres://home_cooking:''${DB_PASS}@host.docker.internal:6432/home_cooking?sslmode=disable"
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
