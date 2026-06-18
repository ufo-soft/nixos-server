{ config, pkgs, lib, ... }:

{
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;

    age = {
      # The age private key must exist on the server at this path before first rebuild.
      # Generate with: age-keygen -o /var/lib/sops-nix/key.txt
      # Add the public key to secrets/.sops.yaml, then encrypt secrets with: sops secrets/secrets.yaml
      keyFile = "/var/lib/sops-nix/key.txt";
      sshKeyPaths = []; # Don't derive age keys from SSH keys
    };

    secrets = {
      "ghcr-token" = {
        owner = "root";
      };

      "cloudflare-api-token" = {
        owner = "root";
      };

      "cloudflare-api-email" = {
        owner = "root";
      };

      "grafana-admin-password" = {
        owner = "root";
        restartUnits = [ "grafana-env.service" "docker-grafana.service" ];
      };

      "postgres-exporter-dsn" = {
        owner = "root";
        restartUnits = [ "postgres-exporter-env.service" "docker-postgres-exporter.service" ];
      };

      "auth-service/jwt-secret" = {
        owner = "root";
      };

      "origin-cert-pem" = {
        owner = "root";
      };

      "origin-cert-key" = {
        owner = "root";
      };

      # mariasfamilyarchive.com origin CA certificate
      "origin-cert-pem-familyarchive" = {
        owner = "root";
      };

      "origin-cert-key-familyarchive" = {
        owner = "root";
      };

      # family-archive app secrets
      "family-archive/session-secret" = {
        owner = "root";
      };

      "family-archive/admin-email" = {
        owner = "root";
      };

      "family-archive/admin-password" = {
        owner = "root";
      };

      "family-archive/database-password" = {
        owner = "root";
        restartUnits = [ "db-passwords.service" "family-archive-env.service" ];
      };

      "family-archive/s3-bucket" = {
        owner = "root";
      };

      "family-archive/s3-region" = {
        owner = "root";
      };

      "family-archive/aws-access-key-id" = {
        owner = "root";
      };

      "family-archive/aws-secret-access-key" = {
        owner = "root";
      };

      "backup-encryption-key" = {
        owner = "root";
      };

      # Healthchecks
      "healthchecks/database-password" = {
        owner = "root";
        restartUnits = [ "db-passwords.service" "healthchecks-env.service" ];
      };

      "healthchecks/secret-key" = {
        owner = "root";
        restartUnits = [ "healthchecks-env.service" "docker-healthchecks.service" ];
      };

      "healthchecks/superuser-email" = {
        owner = "root";
      };

      "healthchecks/superuser-password" = {
        owner = "root";
      };

      "healthchecks/api-key" = {
        owner = "root";
        restartUnits = [ "grafana-env.service" "docker-grafana.service" ];
      };

      "root-password" = {
        owner = "root";
        neededForUsers = true;
      };

      # home-cooking app secrets
      "home-cooking/database-password" = {
        owner = "root";
        restartUnits = [ "db-passwords.service" "home-cooking-env.service" ];
      };

      # PgBouncer lookup user for auth_query
      "pgbouncer/lookup-password" = {
        owner = "root";
        restartUnits = [ "db-passwords.service" "pgbouncer-auth.service" ];
      };
    };
  };
}
