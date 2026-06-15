{ config, pkgs, lib, ... }:

{
  # Traefik static configuration
  environment.etc."traefik/traefik.yml".text = builtins.toJSON {
    entryPoints = {
      web = {
        address = ":80";
        http.redirections.entryPoint = {
          to = "websecure";
          scheme = "https";
        };
      };
      websecure = {
        address = ":443";
      };
    };

    certificatesResolvers.letsencrypt.acme = {
      email = "tim@timothymarias.com";
      storage = "/acme/acme.json";
      dnsChallenge = {
        provider = "cloudflare";
        delayBeforeCheck = 10;
      };
    };

    providers.docker = {
      endpoint = "tcp://docker-socket-proxy:2375";
      exposedByDefault = false;
      network = "proxy-net";
    };

    providers.file = {
      filename = "/etc/traefik/dynamic.yml";
    };

    # Metrics endpoint — internal only, not exposed publicly
    entryPoints.metrics = {
      address = ":8082";
    };
    metrics.prometheus = {
      entryPoint = "metrics";
    };

    log.level = "WARN";
    accessLog = {};
  };

  # Traefik dynamic configuration — middlewares available to all routers
  environment.etc."traefik/dynamic.yml".text = builtins.toJSON {
    # Cloudflare Origin CA certificate for proxied domains
    tls.certificates = [
      {
        certFile = "/certs/timothymarias.com.pem";
        keyFile = "/certs/timothymarias.com.key";
      }
      {
        certFile = "/certs/mariasfamilyarchive.com.pem";
        keyFile = "/certs/mariasfamilyarchive.com.key";
      }
    ];

    http.middlewares = {
      rate-limit = {
        rateLimit = {
          average = 100;
          burst = 200;
          period = "1m";
        };
      };
      secure-headers = {
        headers = {
          stsSeconds = 31536000;
          stsIncludeSubdomains = true;
          stsPreload = true;
          forceSTSHeader = true;
          contentTypeNosniff = true;
          frameDeny = true;
          browserXssFilter = true;
          referrerPolicy = "strict-origin-when-cross-origin";
          contentSecurityPolicy = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'";
        };
      };
      # Same as secure-headers but allows iframes from same origin (for TinyMCE, etc.)
      secure-headers-sameorigin = {
        headers = {
          stsSeconds = 31536000;
          stsIncludeSubdomains = true;
          stsPreload = true;
          forceSTSHeader = true;
          contentTypeNosniff = true;
          customFrameOptionsValue = "SAMEORIGIN";
          browserXssFilter = true;
          referrerPolicy = "strict-origin-when-cross-origin";
          contentSecurityPolicy = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'self'";
        };
      };
      # Grafana needs 'unsafe-eval' for plugins like Infinity datasource
      secure-headers-grafana = {
        headers = {
          stsSeconds = 31536000;
          stsIncludeSubdomains = true;
          stsPreload = true;
          forceSTSHeader = true;
          contentTypeNosniff = true;
          frameDeny = true;
          browserXssFilter = true;
          referrerPolicy = "strict-origin-when-cross-origin";
          contentSecurityPolicy = "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self' http://healthchecks:8000; frame-ancestors 'none'";
        };
      };
      # Stricter rate limit for authentication endpoints
      rate-limit-auth = {
        rateLimit = {
          average = 10;
          burst = 20;
          period = "1m";
        };
      };
      # ForwardAuth — delegates authentication to your auth service.
      # Requests are forwarded to the auth service; 2xx = allow, 4xx = deny.
      forward-auth = {
        forwardAuth = {
          address = "http://auth-service:8080/verify"; # TODO: your auth service endpoint
          trustForwardHeader = true;
          authResponseHeaders = [ "X-User-Id" "X-User-Role" ];
        };
      };
    };
  };

  virtualisation.oci-containers.containers.traefik = {
    image = "traefik@sha256:f79c88ed5252ae1e31c757a9796d751461ddb502437b8d8526db9e12605a82eb";
    ports = [
      "80:80"
      "443:443"
    ];
    volumes = [
      "/etc/traefik/traefik.yml:/traefik.yml:ro"
      "/etc/traefik/dynamic.yml:/etc/traefik/dynamic.yml:ro"
      "/run/traefik/certs:/certs:ro"
      "traefik-acme:/acme"
    ];
    environment = {};
    environmentFiles = [
      "/run/traefik/env"
    ];
    extraOptions = [
      "--network=proxy-net"
    ];
    labels = {
      "traefik.enable" = "false"; # Traefik doesn't route to itself
    };
  };

  # Ensure Traefik starts after networks and socket proxy exist
  systemd.services.docker-traefik = {
    after = [
      "docker-network-proxy-net.service"
      "docker-network-monitoring-net.service"
      "docker-docker-socket-proxy.service"
    ];
    requires = [
      "docker-network-proxy-net.service"
      "docker-network-monitoring-net.service"
      "docker-docker-socket-proxy.service"
    ];
    # Connect Traefik to monitoring-net so Prometheus can scrape its metrics
    postStart = "${pkgs.docker}/bin/docker network connect monitoring-net traefik 2>/dev/null || true";
  };

  # Write Cloudflare API token to a file Traefik can read
  systemd.services.traefik-env = {
    description = "Generate Traefik environment file from secrets";
    after = [ "sops-nix.service" ];
    before = [ "docker-traefik.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "traefik-env" ''
        mkdir -p /run/traefik/certs
        {
          echo "CF_DNS_API_TOKEN=$(cat ${config.sops.secrets."cloudflare-api-token".path})"
          echo "CF_API_EMAIL=$(cat ${config.sops.secrets."cloudflare-api-email".path})"
        } > /run/traefik/env
        chmod 600 /run/traefik/env
        cp ${config.sops.secrets."origin-cert-pem".path} /run/traefik/certs/timothymarias.com.pem
        cp ${config.sops.secrets."origin-cert-key".path} /run/traefik/certs/timothymarias.com.key
        chmod 644 /run/traefik/certs/timothymarias.com.pem
        chmod 600 /run/traefik/certs/timothymarias.com.key

        cp ${config.sops.secrets."origin-cert-pem-familyarchive".path} /run/traefik/certs/mariasfamilyarchive.com.pem
        cp ${config.sops.secrets."origin-cert-key-familyarchive".path} /run/traefik/certs/mariasfamilyarchive.com.key
        chmod 644 /run/traefik/certs/mariasfamilyarchive.com.pem
        chmod 600 /run/traefik/certs/mariasfamilyarchive.com.key
      '';
    };
  };
}
