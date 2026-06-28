{ config, pkgs, lib, ... }:

# Private mesh transport between machines.
# Replaces the hand-rolled WireGuard tunnel in docs/MULTI-SITE-PLAN.md —
# Tailscale is WireGuard underneath, but with NAT traversal, so neither
# machine needs a forwarded UDP port. Admin/replication traffic rides the
# tailnet; nothing here is reachable from the public internet.
#
# Auth is unattended: the node brings itself up using a sops-managed auth key.
# Use a *reusable, pre-approved, tagged* key (tag:server) generated in the
# Tailscale admin console so rebuilds and re-installs don't need interaction.

let
  cfg = config.services.tailscaleMesh;
in
{
  options.services.tailscaleMesh = {
    enable = lib.mkEnableOption "Tailscale mesh networking";

    authKeyFile = lib.mkOption {
      type = lib.types.path;
      default = config.sops.secrets."tailscale-authkey".path;
      description = "Path to the file containing the Tailscale auth key.";
    };

    extraUpFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--advertise-tags=tag:server" "--ssh" ];
      description = "Extra flags passed to `tailscale up`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      # Apply the auth key declaratively on activation; idempotent across rebuilds.
      authKeyFile = cfg.authKeyFile;
      extraUpFlags = cfg.extraUpFlags;
      # Open the firewall for tailscale traffic and let it manage its own routing.
      openFirewall = true;
    };

    # Trust the tailnet interface so tailnet peers can reach services bound to it
    # (SSH, Postgres replication, monitoring) without per-port firewall rules.
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
  };
}