{ config, pkgs, lib, modulesPath, ... }:

# Custom NixOS installer ISO.
#
# Goal: boot machine #2 from this image and have it come up already on the
# tailnet, with your SSH key authorized, so the rest of the install is driven
# from the laptop over the mesh — no keyboard/monitor, no LAN IP hunting.
#
# What is baked in:  SSH key, sshd, Tailscale (auto-joins via baked auth key).
# What is NOT baked in:  hardware-configuration.nix and the real server config.
# Those are generated/applied AFTER booting, because they depend on the actual
# disks and hardware of machine #2.
#
# Build:   nix build .#installer        (wired up in flake.nix)
# Result:  ./result/iso/*.iso  →  flash with dd / Etcher
#
# SECURITY NOTE: the auth key below is embedded in the ISO in plaintext. Use a
# short-lived, single-use Tailscale auth key for the install, then revoke it.
# Do not commit a real key here — keep this placeholder and substitute at build
# time, or read it from a sops secret available on the build host.

{
  imports = [
    # Minimal graphical-less installer base from nixpkgs.
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    # Shared mesh transport — same module the real hosts use.
    ../modules/tailscale.nix
  ];

  # --- Remote access ---------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Same key as the deploy user on the real server (see modules/base.nix).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJvpe/fxnamo6zzOVoxK3WfouV1LyIrd5JCHXvfyH+v timmarias@Tims-MacBook-Pro.local"
  ];

  # --- Mesh ------------------------------------------------------------------
  # The installer joins the tailnet so the install can be driven over Tailscale.
  # Reuses modules/tailscale.nix, but points authKeyFile at a plaintext file
  # written into the image rather than a sops secret (sops isn't decrypted in
  # the live installer — no age key present).
  services.tailscaleMesh = {
    enable = true;
    authKeyFile = "/etc/tailscale-installer-authkey";
    extraUpFlags = [ "--advertise-tags=tag:installer" ];
  };

  # Embed the throwaway install-time auth key. REPLACE before building, REVOKE
  # after install. Single-use + tagged so it can't linger.
  environment.etc."tailscale-installer-authkey".text = "tskey-auth-REPLACE-ME";

  # --- Convenience for the install ------------------------------------------
  environment.systemPackages = with pkgs; [
    git          # to clone this flake onto the target
    parted       # partitioning
    vim
  ];

  # Speeds up `nixos-install` by having flakes/nix-command ready in the live env.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}