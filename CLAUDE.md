# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Declarative NixOS configuration for a self-hosted server running Kotlin/Ktor backends as Docker containers (GraalVM native images from GHCR) behind Traefik, with PostgreSQL + PgBouncer, and a full observability stack.

## Key Commands

```bash
# Build and apply configuration (run on the server)
# --impure is required because app configs read image digests from /var/lib/deploy/ at eval time
sudo nixos-rebuild switch --flake .#server --impure

# Dry-run to preview changes without applying
nixos-rebuild dry-activate --flake .#server --impure

# Build only (check for evaluation errors)
nixos-rebuild build --flake .#server --impure

# Evaluate a specific config value
nix eval .#nixosConfigurations.server.config.networking.hostName

# Rollback to previous generation
sudo nixos-rebuild switch --rollback

# Deploy an app image update
./scripts/deploy.sh <app-name> <sha256:digest>

# Create a new app database
./scripts/db-create.sh <app-name> <db-user> <db-name>

# Manage backups
./scripts/backup-restore.sh list|restore-db|restore-volume

# Manage cron jobs
./scripts/cron.sh                   # list timers
./scripts/cron.sh status            # next/last run times
./scripts/cron.sh logs <app> <job>  # view logs
./scripts/cron.sh run <app> <job>   # trigger immediately

# Edit encrypted secrets
sops secrets/secrets.yaml
```

## Architecture

- **flake.nix** — Entry point. Pins nixpkgs (by commit hash) + sops-nix inputs, defines single `nixosConfigurations.server` output.
- **configuration.nix** — Top-level imports only. Add new app imports here.
- **modules/** — Each file owns one concern (base, ssh, firewall, hardening, secrets, docker, postgresql, traefik, monitoring, cron, backups).
- **apps/** — One file per app container. `_template.nix` is the canonical starting point.
- **secrets/** — sops-nix encrypted secrets (age keys). `.sops.yaml` has key config.
- **scripts/** — Operational helpers (deploy, db-create, backup-restore, cron).

## Adding a New App

1. Copy `apps/_template.nix` to `apps/<name>.nix`
2. Fill in `appName`, `domain`, `imageSha`, `ghOrg`
3. Add database entry to the `appDatabases` list in `modules/postgresql.nix`
4. Import the new file in `configuration.nix`
5. Add any secrets to `secrets/secrets.yaml` and declare in `modules/secrets.nix`

## Conventions

- App names use kebab-case (`my-app`); database users/names use snake_case (`my_app`)
- All Docker images (app and infrastructure) are pinned by digest (`sha256:...`), never by tag
- Each app gets its own Docker network isolation — connects to `proxy-net` for Traefik routing, reaches PostgreSQL via `host.docker.internal:6432` (PgBouncer)
- Apps cannot communicate with each other
- Secrets use sops-nix with age encryption; never store plaintext secrets
- PostgreSQL has per-app users with scoped `pg_hba.conf` rules
- Traefik labels on containers handle routing, TLS, and middleware (ForwardAuth, rate-limit, rate-limit-auth, secure-headers)
- Traefik accesses Docker via a socket proxy (`tecnativa/docker-socket-proxy`), not a direct socket mount
- The `deploy` user has scoped sudo (nixos-rebuild, systemctl, nix-collect-garbage only), not blanket wheel access
- Backups are GPG-encrypted using a sops-managed symmetric key
- App cron jobs are registered via `services.appCronJobs` in app nix files — each job gets a systemd timer + optional Healthchecks heartbeat ping
- Healthchecks (self-hosted) provides heartbeat monitoring for cron jobs, integrated into Grafana via the Infinity datasource
- TODOs in the codebase mark placeholders that need real values for deployment
