{ config, pkgs, lib, ... }:

{
  networking.firewall = {
    enable = true;

    allowedTCPPorts = [ 22 80 443 ];
    allowedUDPPorts = [];

    # Block Docker containers from reaching the home LAN.
    # Allow containers to reach PgBouncer (6432), Redis cache (6379), Redis
    # queue (6380), and allow established connections (for docker-proxy).
    extraCommands = ''
      # Block containers from initiating connections to the home LAN, but allow responses
      iptables -C FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

      iptables -C FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate NEW -j DROP 2>/dev/null || \
        iptables -I FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate NEW -j DROP

      # Order matters: -I inserts at position 1, so the last -I ends up first.
      # Final order: ESTABLISHED → PgBouncer → DROP
      iptables -C INPUT -s 172.16.0.0/12 -p tcp -j DROP 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp -j DROP

      # Log dropped container traffic (inserted after DROP so it fires first due to -I ordering)
      iptables -C INPUT -s 172.16.0.0/12 -p tcp -m conntrack --ctstate NEW -j LOG --log-prefix "iptables-docker-drop: " --log-level 4 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp -m conntrack --ctstate NEW -j LOG --log-prefix "iptables-docker-drop: " --log-level 4

      iptables -C INPUT -s 172.16.0.0/12 -p tcp --dport 6432 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp --dport 6432 -j ACCEPT

      # Redis cache (6379) and queue (6380) — same pattern as PgBouncer above.
      # Redis itself binds only to loopback + the docker gateway, so this
      # opens nothing to the LAN; it only permits the container bridge range.
      iptables -C INPUT -s 172.16.0.0/12 -p tcp --dport 6379 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp --dport 6379 -j ACCEPT

      iptables -C INPUT -s 172.16.0.0/12 -p tcp --dport 6380 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp --dport 6380 -j ACCEPT

      iptables -C INPUT -s 172.16.0.0/12 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    '';

    extraStopCommands = ''
      iptables -D FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
      iptables -D FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp --dport 6432 -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp --dport 6379 -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp --dport 6380 -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp -m conntrack --ctstate NEW -j LOG --log-prefix "iptables-docker-drop: " --log-level 4 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp -j DROP 2>/dev/null || true
    '';
  };
}
