{ config, pkgs, lib, ... }:

{
  # --- Prometheus configuration ---

  environment.etc."prometheus/prometheus.yml".text = builtins.toJSON {
    global = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
    };

    scrape_configs = [
      {
        job_name = "prometheus";
        static_configs = [{ targets = [ "localhost:9090" ]; }];
      }
      {
        job_name = "node-exporter";
        static_configs = [{ targets = [ "node-exporter:9100" ]; }];
      }
      {
        job_name = "postgres-exporter";
        static_configs = [{ targets = [ "postgres-exporter:9187" ]; }];
      }
      {
        job_name = "traefik";
        static_configs = [{ targets = [ "traefik:8082" ]; }];
      }
      {
        job_name = "otel-collector";
        static_configs = [{ targets = [ "otel-collector:8888" ]; }];
      }
      {
        job_name = "otel-apps";
        static_configs = [{ targets = [ "otel-collector:8889" ]; }];
      }
    ];
  };

  # --- OTel Collector configuration ---

  environment.etc."otel-collector/config.yaml".text = builtins.toJSON {
    receivers = {
      otlp = {
        protocols = {
          grpc.endpoint = "0.0.0.0:4317";
          http.endpoint = "0.0.0.0:4318";
        };
      };
    };

    processors = {
      batch = {
        timeout = "5s";
        send_batch_size = 1024;
      };
    };

    exporters = {
      prometheus = {
        endpoint = "0.0.0.0:8889";
        namespace = "otel";
      };
      loki = {
        endpoint = "http://loki:3100/loki/api/v1/push";
      };
    };

    service = {
      telemetry = {
        metrics = {
          address = "0.0.0.0:8888";
        };
      };
      pipelines = {
        metrics = {
          receivers = [ "otlp" ];
          processors = [ "batch" ];
          exporters = [ "prometheus" ];
        };
        logs = {
          receivers = [ "otlp" ];
          processors = [ "batch" ];
          exporters = [ "loki" ];
        };
      };
    };
  };

  # --- Loki configuration ---

  environment.etc."loki/config.yaml".text = builtins.toJSON {
    auth_enabled = false;

    server.http_listen_port = 3100;

    common = {
      path_prefix = "/loki";
      storage.filesystem.chunks_directory = "/loki/chunks";
      storage.filesystem.rules_directory = "/loki/rules";
      replication_factor = 1;
      ring.kvstore.store = "inmemory";
    };

    schema_config.configs = [{
      from = "2024-01-01";
      store = "tsdb";
      object_store = "filesystem";
      schema = "v13";
      index = {
        prefix = "index_";
        period = "24h";
      };
    }];
  };

  # --- Grafana provisioning ---
  # Written to /run/grafana/provisioning by the grafana-env service (not environment.etc,
  # because Docker can't follow NixOS /etc symlinks into the Nix store)

  # --- Containers ---

  virtualisation.oci-containers.containers = {
    prometheus = {
      image = "prom/prometheus@sha256:6927e0919a144aa7616fd0137d4816816d42f6b816de3af269ab065250859a62";
      volumes = [
        "/etc/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
        "prometheus-data:/prometheus"
      ];
      cmd = [
        "--config.file=/etc/prometheus/prometheus.yml"
        "--storage.tsdb.retention.time=30d"
      ];
      extraOptions = [ "--network=monitoring-net" ];
    };

    grafana = {
      image = "grafana/grafana@sha256:8b37a2f028f164ce7b9889e1765b9d6ee23fec80f871d156fbf436d6198d32b7";
      volumes = [
        "grafana-data:/var/lib/grafana"
        "/run/grafana/provisioning:/etc/grafana/provisioning:ro"
      ];
      environment = {
        GF_SECURITY_ADMIN_USER = "admin";
        # GF_SECURITY_ADMIN_PASSWORD set via environmentFiles
        GF_SERVER_ROOT_URL = "https://grafana.timothymarias.com";
        GF_INSTALL_PLUGINS = "yesoreyeram-infinity-datasource";
      };
      environmentFiles = [ "/run/grafana/env" ];
      extraOptions = [
        "--network=monitoring-net"
        "--network=proxy-net"
      ];
      labels = {
        "traefik.enable" = "true";
        "traefik.http.routers.grafana.rule" = "Host(`grafana.timothymarias.com`)";
        "traefik.http.routers.grafana.entrypoints" = "websecure";
        "traefik.http.routers.grafana.tls" = "true";
        "traefik.http.routers.grafana.middlewares" = "secure-headers@file";
        "traefik.http.services.grafana.loadbalancer.server.port" = "3000";
      };
    };

    loki = {
      image = "grafana/loki@sha256:58a6c186ce78ba04d58bfe2a927eff296ba733a430df09645d56cdc158f3ba08";
      volumes = [
        "/etc/loki/config.yaml:/etc/loki/config.yaml:ro"
        "loki-data:/loki"
      ];
      cmd = [ "-config.file=/etc/loki/config.yaml" ];
      extraOptions = [ "--network=monitoring-net" ];
    };

    otel-collector = {
      image = "otel/opentelemetry-collector-contrib@sha256:85ac41c2db88d0df9bd6145e608a3cb023f5d8443868adbfbbf66efb51087917";
      volumes = [
        "/etc/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro"
      ];
      extraOptions = [
        "--network=monitoring-net"
        "--network=proxy-net" # Apps on proxy-net send OTLP here
      ];
    };

    node-exporter = {
      image = "prom/node-exporter@sha256:c99d7ee4d12a38661788f60d9eca493f08584e2e544bbd3b3fca64749f86b848";
      volumes = [
        "/proc:/host/proc:ro"
        "/sys:/host/sys:ro"
        "/:/host/rootfs:ro"
        "/var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro"
      ];
      cmd = [
        "--path.procfs=/host/proc"
        "--path.sysfs=/host/sys"
        "--path.rootfs=/host/rootfs"
        "--collector.systemd"
        "--collector.systemd.unit-include=cron-.*\\.(service|timer)"
      ];
      extraOptions = [
        "--network=monitoring-net"
      ];
    };

    healthchecks = {
      image = "healthchecks/healthchecks@sha256:6b5f593d40994345053f05f86decfa9e17ab1e4422df2ae58abd032a7b14d8f6";
      volumes = [
        "healthchecks-data:/data"
      ];
      environment = {
        ALLOWED_HOSTS = "*";
        APPRISE_ENABLED = "False";
        DEBUG = "False";
        DEFAULT_FROM_EMAIL = "healthchecks@timothymarias.com";
        PING_BODY_LIMIT = "10000";
        REGISTRATION_OPEN = "False";
        SITE_NAME = "Healthchecks";
        SITE_ROOT = "https://healthchecks.timothymarias.com";
      };
      environmentFiles = [ "/run/healthchecks/env" ];
      extraOptions = [
        "--network=monitoring-net"
        "--network=proxy-net"
        "--add-host=host.docker.internal:host-gateway"
      ];
      labels = {
        "traefik.enable" = "true";
        "traefik.http.routers.healthchecks.rule" = "Host(`healthchecks.timothymarias.com`)";
        "traefik.http.routers.healthchecks.entrypoints" = "websecure";
        "traefik.http.routers.healthchecks.tls" = "true";
        "traefik.http.routers.healthchecks.middlewares" = "rate-limit@file,secure-headers@file";
        "traefik.http.services.healthchecks.loadbalancer.server.port" = "8000";
      };
    };

    postgres-exporter = {
      image = "prometheuscommunity/postgres-exporter@sha256:6999a7657e2f2fb0ca6ebf417213eebf6dc7d21b30708c622f6fcb11183a2bb0";
      environmentFiles = [
        "/run/postgres-exporter/env"
      ];
      extraOptions = [
        "--network=monitoring-net"
        "--add-host=host.docker.internal:host-gateway"
      ];
    };
  };

  # Generate Grafana env file and provisioning config
  # Provisioning is written here (not environment.etc) because Docker can't follow
  # NixOS symlinks inside a bind-mounted directory.
  systemd.services.grafana-env = let
    datasourcesConfig = pkgs.writeText "grafana-datasources.yaml" (builtins.toJSON {
      apiVersion = 1;
      datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          access = "proxy";
          url = "http://prometheus:9090";
          isDefault = true;
        }
        {
          name = "Loki";
          type = "loki";
          uid = "loki";
          access = "proxy";
          url = "http://loki:3100";
        }
        {
          name = "Healthchecks";
          type = "yesoreyeram-infinity-datasource";
          uid = "healthchecks";
          access = "proxy";
          jsonData = {
            auth_method = "apiKey";
            apiKeyKey = "X-Api-Key";
            apiKeyType = "header";
          };
          secureJsonData = {
            apiKeyValue = "$__file{/run/grafana/healthchecks-api-key}";
          };
        }
      ];
    });
    dashboardProvisioningConfig = pkgs.writeText "grafana-dashboards.yaml" (builtins.toJSON {
      apiVersion = 1;
      providers = [
        {
          name = "default";
          orgId = 1;
          folder = "";
          type = "file";
          disableDeletion = false;
          updateIntervalSeconds = 60;
          options.path = "/etc/grafana/provisioning/dashboards/json";
        }
      ];
    });
    dashboardsDir = ../dashboards;
  in {
    description = "Generate Grafana environment and provisioning files";
    after = [ "sops-nix.service" ];
    before = [ "docker-grafana.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "grafana-env" ''
        mkdir -p /run/grafana/provisioning/datasources
        mkdir -p /run/grafana/provisioning/dashboards/json

        # Admin password
        echo "GF_SECURITY_ADMIN_PASSWORD=$(cat ${config.sops.secrets."grafana-admin-password".path})" > /run/grafana/env
        chmod 600 /run/grafana/env

        # Healthchecks API key for Grafana Infinity datasource
        # Written to /var/lib/healthchecks/api-key after first login:
        #   echo -n "<key>" | sudo tee /var/lib/healthchecks/api-key
        #   sudo systemctl restart grafana-env docker-grafana
        HC_KEY="/var/lib/healthchecks/api-key"
        if [ -f "$HC_KEY" ]; then
          cp "$HC_KEY" /run/grafana/healthchecks-api-key
          chmod 600 /run/grafana/healthchecks-api-key
        else
          echo "WARNING: $HC_KEY not found — Healthchecks datasource will not work until API key is set"
          echo "placeholder" > /run/grafana/healthchecks-api-key
          chmod 600 /run/grafana/healthchecks-api-key
        fi

        # Datasource provisioning
        cp ${datasourcesConfig} /run/grafana/provisioning/datasources/datasources.yaml

        # Dashboard provisioning
        cp ${dashboardProvisioningConfig} /run/grafana/provisioning/dashboards/dashboards.yaml
        cp ${dashboardsDir}/*.json /run/grafana/provisioning/dashboards/json/
      '';
    };
  };

  # Generate postgres-exporter env file from sops secret
  systemd.services.postgres-exporter-env = {
    description = "Generate postgres-exporter environment file from secrets";
    after = [ "sops-nix.service" ];
    before = [ "docker-postgres-exporter.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "postgres-exporter-env" ''
        mkdir -p /run/postgres-exporter
        echo "DATA_SOURCE_NAME=$(cat ${config.sops.secrets."postgres-exporter-dsn".path})" > /run/postgres-exporter/env
        chmod 600 /run/postgres-exporter/env
      '';
    };
  };

  # Generate Healthchecks env file from sops secrets
  systemd.services.healthchecks-env = {
    description = "Generate Healthchecks environment file from secrets";
    after = [ "sops-nix.service" ];
    before = [ "docker-healthchecks.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "healthchecks-env" ''
        mkdir -p /run/healthchecks
        DB_PASS="$(cat ${config.sops.secrets."healthchecks/database-password".path})"
        {
          echo "DB=postgres"
          echo "DB_HOST=host.docker.internal"
          echo "DB_PORT=6432"
          echo "DB_NAME=healthchecks"
          echo "DB_USER=healthchecks"
          echo "DB_PASSWORD=''${DB_PASS}"
          echo "SECRET_KEY=$(cat ${config.sops.secrets."healthchecks/secret-key".path})"
          echo "SUPERUSER_EMAIL=$(cat ${config.sops.secrets."healthchecks/superuser-email".path})"
          echo "SUPERUSER_PASSWORD=$(cat ${config.sops.secrets."healthchecks/superuser-password".path})"
        } > /run/healthchecks/env
        chmod 600 /run/healthchecks/env
      '';
    };
  };

  # Ensure monitoring containers start after networks exist
  systemd.services = {
    docker-prometheus.after = [ "docker-network-monitoring-net.service" ];
    docker-prometheus.requires = [ "docker-network-monitoring-net.service" ];

    docker-grafana.after = [ "docker-network-monitoring-net.service" "docker-network-proxy-net.service" "grafana-env.service" ];
    docker-grafana.requires = [ "docker-network-monitoring-net.service" "docker-network-proxy-net.service" "grafana-env.service" ];

    # Connect Grafana to proxy-net after creation (oci-containers only supports one --network)
    docker-grafana.postStart = "${pkgs.docker}/bin/docker network connect proxy-net grafana 2>/dev/null || true";

    docker-loki.after = [ "docker-network-monitoring-net.service" ];
    docker-loki.requires = [ "docker-network-monitoring-net.service" ];

    docker-otel-collector.after = [ "docker-network-monitoring-net.service" "docker-network-proxy-net.service" ];
    docker-otel-collector.requires = [ "docker-network-monitoring-net.service" "docker-network-proxy-net.service" ];
    docker-otel-collector.postStart = "${pkgs.docker}/bin/docker network connect proxy-net otel-collector 2>/dev/null || true";

    docker-node-exporter.after = [ "docker-network-monitoring-net.service" ];
    docker-node-exporter.requires = [ "docker-network-monitoring-net.service" ];

    docker-postgres-exporter.after = [ "docker-network-monitoring-net.service" "postgres-exporter-env.service" ];
    docker-postgres-exporter.requires = [ "docker-network-monitoring-net.service" "postgres-exporter-env.service" ];

    docker-healthchecks.after = [ "docker-network-monitoring-net.service" "docker-network-proxy-net.service" "healthchecks-env.service" "pgbouncer.service" ];
    docker-healthchecks.requires = [ "docker-network-monitoring-net.service" "docker-network-proxy-net.service" "healthchecks-env.service" ];
    docker-healthchecks.postStart = "${pkgs.docker}/bin/docker network connect proxy-net healthchecks 2>/dev/null || true";
  };
}
