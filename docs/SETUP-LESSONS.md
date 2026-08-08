# Setup Lessons Learned

Hard-won knowledge from actually setting up this server. Read this before you start.

## NixOS is declarative — it will remove things you don't declare

If your config defines a `deploy` user but not the `user` account you've been using, `nixos-rebuild switch` **will delete that user**. You will be locked out if `deploy` doesn't have a working SSH key and the firewall allows port 22.

**Before every `nixos-rebuild switch`, verify:**
1. Your SSH user exists in the config (`modules/base.nix`)
2. Your SSH public key is on that user
3. Port 22 is in `allowedTCPPorts` in `modules/firewall.nix`
4. `services.openssh.enable = true` in `modules/ssh.nix`

If you get any of these wrong, you need physical access (keyboard + monitor) to recover.

## The firewall does NOT auto-open SSH

Despite comments you may see in NixOS configs, the firewall does not automatically open port 22 just because `services.openssh.enable = true`. You must explicitly add `22` to `networking.firewall.allowedTCPPorts`. If you don't, you will lose SSH access on the next rebuild.

## Always dry-run before switching

```bash
nixos-rebuild build --flake ~/nixos-server#server
```

This catches evaluation errors without changing the running system. It won't catch runtime issues (like a service failing to start), but it prevents the worst mistakes.

## Recovery options when locked out

In order of least to most painful:

1. **Boot previous generation** — Reboot, select the previous entry in the systemd-boot menu. This restores the old config including users and firewall rules. Requires keyboard + monitor.

2. **USB tethering** — If the server has no ethernet (e.g., you moved it to your desk), plug your phone in via USB-C and enable USB tethering. The server will pick up the interface. Bring it up with:
   ```bash
   ip link set <interface> up
   dhcpcd <interface>
   ```
   Find the interface name with `ip link`. It'll be something like `enp0s20f0u1`.

3. **NixOS installer USB** — Boot from the installer, mount the drive, chroot in, fix the config.

## sops-nix setup order

1. Generate age key on the server (`age-keygen -o /var/lib/sops-nix/key.txt`)
2. Generate age key on your local machine (`age-keygen -o ~/Library/Application Support/sops/age/keys.txt` on macOS)
3. Put **both** public keys in `.sops.yaml` (repo root, not `secrets/`)
4. Create `secrets/secrets.yaml` with `sops secrets/secrets.yaml`
5. If you already created secrets with only the server key, run `sops updatekeys secrets/secrets.yaml` **on the server** (as root, with `SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt`) to re-encrypt for both keys

**Common mistakes:**
- `.sops.yaml` in `secrets/` instead of repo root — sops won't find it
- Only the server's age key in `.sops.yaml` — you can't edit secrets from your local machine
- `path_regex` doesn't match the file path relative to `.sops.yaml` location

## Git on the server

The server needs to pull the config repo. Set up SSH for GitHub on the server:

```bash
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub
# Add to GitHub → Settings → SSH keys
```

Use SSH URLs (`git@github.com:...`), not HTTPS. HTTPS will prompt for credentials that won't work without a token embedded in the URL.

If you get "not owned by current user" errors when rebuilding, it's because you pulled as a different user (e.g., root). Fix with:
```bash
sudo chown -R deploy:users ~/nixos-server
```

## DNS can break during rebuild

NixOS may switch network managers during a rebuild (e.g., from NetworkManager to dhcpcd). If DNS stops working:

```bash
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

## Static IP setup

Without a static IP, DHCP may assign a different address after a reboot. Set it in `configuration.nix`:

```nix
networking.interfaces.<your-interface>.ipv4.addresses = [{
  address = "192.168.1.7";  # pick an IP outside your router's DHCP range
  prefixLength = 24;
}];
networking.defaultGateway = "192.168.1.1";
networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
```

Find your interface name: `ip route show default` — it's the name after `dev`.

## Docker vs Podman

NixOS defaults `virtualisation.oci-containers` to **podman**, not Docker. If you want Docker, you must set:

```nix
virtualisation.oci-containers.backend = "docker";
```

Without this, containers start as `podman-*` services and may not work with Docker-specific features (like Docker networks).

## systemd ExecStart is not a shell

This does NOT work in `serviceConfig.ExecStart`:

```nix
ExecStart = "docker network create my-net || true";
```

systemd passes `||` and `true` as literal arguments to docker. Wrap in a script:

```nix
ExecStart = pkgs.writeShellScript "create-network" ''
  docker network create my-net || true
'';
```

## Secrets must exist before rebuild

If `modules/secrets.nix` declares a secret that doesn't exist in `secrets/secrets.yaml`, the rebuild will fail. When adding placeholder values, make sure the YAML structure matches what sops-nix expects. Nested keys use `/` in sops-nix:

```yaml
# In secrets.yaml — this creates the secret "auth-service/jwt-secret"
auth-service:
    jwt-secret: placeholder
```

Not:
```yaml
# WRONG — sops treats this as a flat string, not a nested key
auth-service/jwt-secret: placeholder
```

## Port forwarding comes last

Don't expose the server to the internet until:
1. All placeholder credentials are replaced with real values
2. The firewall is properly configured (Docker→LAN isolation)
3. SSH is locked down (key-only, fail2ban)
4. You've verified services are running (`sudo docker ps`, `sudo systemctl --failed`)

## Useful commands

```bash
# See what generation you're running
nixos-rebuild list-generations

# Roll back to previous generation (if something breaks)
sudo nixos-rebuild switch --rollback

# Check all failed services
sudo systemctl --failed

# See running containers
sudo docker ps

# View container logs
sudo docker logs <container-name>

# Test the nix config without applying
nixos-rebuild build --flake ~/nixos-server#server

# Rebuild and switch
cd ~/nixos-server && git pull && sudo nixos-rebuild switch --flake ~/nixos-server#server
```

## Traefik Docker API version mismatch

Traefik v3.3 and v3.4 hardcode Docker API version 1.24, which is rejected by Docker Engine 29+ (minimum API 1.40). The `DOCKER_API_VERSION` environment variable does NOT work — Traefik ignores it.

**Fix:** Use Traefik v3.6+, which has automatic Docker API version negotiation.

## Cloudflare proxy mode vs DNS only

There are two ways to use Cloudflare:

- **DNS only (gray cloud):** Cloudflare just resolves DNS. Traffic goes directly to your server. Traefik handles TLS with Let's Encrypt certs via DNS challenge. Your server's IP is exposed.

- **Proxied (orange cloud):** Cloudflare terminates public TLS, proxies traffic to your server, and provides DDoS protection. Your server uses a Cloudflare Origin CA certificate for the Cloudflare-to-server connection. Your server's IP is hidden.

This config uses **proxied mode** for DDoS protection. Key setup:
1. Generate an Origin CA cert in Cloudflare (SSL/TLS → Origin Server)
2. Store cert + key in sops secrets as `origin-cert-pem` and `origin-cert-key`
3. Set Cloudflare SSL/TLS mode to **Full (strict)**
4. A records must be set to **Proxied** (orange cloud)

The Let's Encrypt / ACME config is kept as a fallback for domains not behind Cloudflare proxy.

## Docker iptables rules and port forwarding

Docker uses iptables NAT (PREROUTING → DNAT) to forward published ports to containers. This means:

1. Traffic to published ports (80, 443) does NOT go through the INPUT chain — it goes through FORWARD
2. Custom iptables rules that DROP traffic from Docker subnets (`172.16.0.0/12`) in FORWARD will also block **response** packets from containers back to clients
3. Always use `--ctstate NEW` on DROP rules and add matching `ESTABLISHED,RELATED` ACCEPT rules

Bad (blocks all traffic including responses):
```bash
iptables -I FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -j DROP
```

Good (only blocks containers from initiating connections to LAN):
```bash
iptables -I FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -m conntrack --ctstate NEW -j DROP
```

Also: `iptables -I` inserts at position 1. If you run multiple `-I` commands, the **last** one ends up at position 1. Reverse the order of your `-I` calls so the final rule order is correct.

## Docker `--internal` networks break port forwarding

Docker's `--internal` flag on networks adds rules to a `DOCKER-INTERNAL` iptables chain that drops traffic not within that network's subnet. These rules are **global** — they affect forwarded traffic to ALL containers, not just those on the internal network. This will break Traefik's published ports.

**Fix:** Don't use `--internal` networks. Use iptables rules in `firewall.nix` to restrict container traffic instead.

## Residential IP and DDNS

Residential ISPs assign dynamic IPs via DHCP. The `cloudflare-ddns.nix` module checks the public IP every 5 minutes and updates Cloudflare A records if it changes. Add new subdomains to the `dnsRecords` list in that file.

## Netgear router quirks

The basic Netgear router UI may not show port forwarding options. Access the full admin UI at `http://192.168.1.1/start.htm` to see the Advanced tab with Port Forwarding under Advanced Setup.

The "Add Custom Service" button may not work (popup blocker or JavaScript issue). Workaround: add a built-in service type (like FTP), then edit it to change the name and port numbers.

## PgBouncer auth_query bootstrap

PgBouncer's `auth_query` looks up app passwords dynamically from `pg_shadow`, so adding a new app doesn't require regenerating any auth files or restarting PgBouncer.

The bootstrap problem (PgBouncer needs a password to connect, but needs to connect to look up passwords) is solved with a minimal static `auth_file` containing only the `pgbouncer` lookup user's plaintext password. All other users are resolved via `auth_query`.

Key details:
- `auth_dbname = postgres` — PgBouncer only connects to the `postgres` database for lookups, avoiding per-database permission issues.
- `pg_shadow` access uses a `SECURITY DEFINER` function (`public.pgbouncer_get_auth`) owned by the postgres superuser. The `pgbouncer` user only has `EXECUTE` on this function, not direct `pg_shadow` access.
- The auth file must contain the **plaintext** password (not the SCRAM hash), because PgBouncer uses it as a client credential to authenticate against Postgres's SCRAM challenge.

## PgBouncer RuntimeDirectory conflicts

Multiple systemd services must NOT share the same `RuntimeDirectory`. PgBouncer uses `/run/pgbouncer/` for its Unix socket. If another service (like the auth file generator) also declares `RuntimeDirectory=pgbouncer`, restarting either service will wipe the other's files.

The auth file generator uses `RuntimeDirectory=pgbouncer-auth` to avoid this. The auth file lives at `/run/pgbouncer-auth/userlist.txt`.

## Traefik file provider must be explicitly configured

Traefik's `dynamic.yml` (middlewares, TLS certs) is only loaded if a file provider is configured in the static config. Having the file mounted into the container is not enough — Traefik ignores it without `providers.file`.

```nix
# In traefik.nix static config
providers.file = {
  filename = "/etc/traefik/dynamic.yml";
};
```

Without this, container labels work (via the Docker provider) but file-defined middlewares like `secure-headers@file` will show "does not exist" errors.

### The same error from a stale in-memory config

That error has a second cause, and this one takes the site down. `dynamic.yml` is bind-mounted from `/etc`, and NixOS swaps the symlink target rather than editing the file in place — which Traefik's file watcher does not notice. It keeps serving the config it loaded at boot.

Adding a middleware and pointing an app at it in the same rebuild hits this every time: the app's label arrives instantly through the Docker provider, while the middleware definition waits on a reload that never comes. Traefik then **drops the router entirely** rather than serving without the middleware, so every request to that host gets Traefik's own bare 404 — an outage, not a degraded page.

The tell is that `grep` finds the middleware in `/etc/traefik/dynamic.yml` while the logs still say it does not exist:

```
ERR error="middleware \"secure-headers-family-archive@file\" does not exist" routerName=family-archive@docker
```

`systemd.services.docker-traefik.restartTriggers` now points at both config store paths, so any content change restarts Traefik automatically. To recover by hand:

```
sudo systemctl restart docker-traefik
```

## Nix string interpolation in shell scripts

In Nix's `''...''` strings (used by `writeShellScript`), `${...}` is Nix interpolation. To get a literal shell variable like `${MY_VAR}`, escape it as `''${MY_VAR}`.

SQL queries with double quotes inside Nix strings get messy fast. Write the SQL to a separate file with `pkgs.writeText` and pass it to `psql -f`:

```nix
ExecStart = let
  sqlFile = pkgs.writeText "query.sql" ''
    SELECT concat('"', col, '"') FROM table;
  '';
in pkgs.writeShellScript "my-script" ''
  psql -Atf ${sqlFile} > /run/output.txt
'';
```

## Port forwarding is required for CI/CD SSH deploys

GitHub Actions runners are on the public internet. If your CI pipeline SSHs into the server to deploy, port 22 must be forwarded on your router to the server's LAN IP. Without it, the SSH connection will time out with `dial tcp: i/o timeout`.

This is separate from the NixOS firewall allowing port 22 — the router is the first hop.
