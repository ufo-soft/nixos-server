{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix

    # Base system
    ./modules/base.nix
    ./modules/ssh.nix
    ./modules/firewall.nix
    ./modules/hardening.nix
    ./modules/secrets.nix

    # Infrastructure
    ./modules/docker.nix
    ./modules/postgresql.nix
    ./modules/redis.nix
    ./modules/traefik.nix
    ./modules/cloudflare-ddns.nix
    ./modules/cron.nix

    # Observability
    ./modules/monitoring.nix
    ./modules/backups.nix

    # Hardware
    ./modules/ups.nix  # disabled by default; enable with services.ups.enable = true

    # Apps — personal
    ./apps/personal/family-archive.nix
    ./apps/personal/home-cooking.nix

    # Apps — ufo-soft
    ./apps/ufo-soft/lupin-api-production.nix
    ./apps/ufo-soft/lupin-api-staging.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "server";

  # Static IP
  networking.interfaces.enp86s0.ipv4.addresses = [{
    address = "192.168.1.7";
    prefixLength = 24;
  }];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "25.11";
}
