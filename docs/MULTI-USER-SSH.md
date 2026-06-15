# Multi-User SSH Plan

Plan for moving from a single shared `deploy` user to named user accounts with role-based permissions, designed to scale across a multi-site mesh.

## Why

Currently there's one shared `deploy` user used by both Tim and GitHub Actions. Shared accounts break audit trails. As the server becomes a team project, each human needs a named account with appropriate permissions. The `deploy` user stays as a CI/CD service account.

## Architecture

```
                    modules/users/
                   /       |       \
             roles.nix  default.nix  keys/
                           |           |
                     team roster    tim.keys
                     (name, role,   alice.keys
                      nodes list)   bob.keys
                           |
                    generates via map:
                   /                  \
          users.users.*       security.sudo.extraRules
```

`mutableUsers = false` stays. Every user change requires a Nix rebuild, which means a git commit, which means an audit trail. This is a feature.

## Roles

| Role | Groups | Sudo Permissions | Who |
|------|--------|-----------------|-----|
| **admin** | docker, systemd-journal | nixos-rebuild, systemctl, nix-collect-garbage, journalctl, mkdir, tee | Tim, trusted co-maintainers |
| **ops** | systemd-journal | systemctl restart/start/stop/status, journalctl, docker logs/ps/inspect (via sudo only) | Developers who deploy and debug |
| **readonly** | systemd-journal | journalctl, systemctl status | Observers, on-call, new members |

### Why ops doesn't get the docker group

Docker group membership is root-equivalent — anyone in it can `docker run -v /:/host` and own the machine. Ops users get read-only docker access through sudo-allowlisted subcommands only (`logs`, `ps`, `inspect`).

## Module Design

### `modules/users/roles.nix` — Role definitions

Defines a custom NixOS option `server.roles` mapping role names to their permissions:

```nix
config.server.roles = {
  admin = {
    extraGroups = [ "docker" "systemd-journal" ];
    sudoCommands = [
      { command = "/run/current-system/sw/bin/nixos-rebuild *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/systemctl *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/nix-collect-garbage *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/journalctl *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/mkdir *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/tee *"; options = [ "NOPASSWD" ]; }
    ];
  };

  ops = {
    extraGroups = [ "systemd-journal" ];
    sudoCommands = [
      { command = "/run/current-system/sw/bin/systemctl restart *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/systemctl start *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/systemctl stop *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/systemctl status *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/journalctl *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/docker logs *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/docker ps *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/docker inspect *"; options = [ "NOPASSWD" ]; }
    ];
  };

  readonly = {
    extraGroups = [ "systemd-journal" ];
    sudoCommands = [
      { command = "/run/current-system/sw/bin/journalctl *"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/systemctl status *"; options = [ "NOPASSWD" ]; }
    ];
  };
};
```

### `modules/users/default.nix` — Team roster

Single source of truth for who has access:

```nix
let
  team = [
    { name = "tim";   role = "admin";    nodes = [ "all" ]; }
    # { name = "alice"; role = "ops";    nodes = [ "all" ]; }
    # { name = "bob";   role = "readonly"; nodes = [ "server" ]; }
  ];

  hostname = config.networking.hostName;

  activeUsers = builtins.filter (u:
    builtins.elem "all" u.nodes || builtins.elem hostname u.nodes
  ) team;
in
{
  # Generate users.users.<name> from roster + role config
  # Generate security.sudo.extraRules from roster + role config
}
```

### `modules/users/keys/` — SSH public keys

One file per person, plain-text, one key per line. Public keys are safe to commit. Referenced via `openssh.authorizedKeys.keyFiles = [ ./keys/${name}.keys ]`.

## SSH Key Management

| Action | Process |
|--------|---------|
| **Add a person** | Add `.keys` file + roster entry, rebuild |
| **Remove a person** | Delete roster entry (or set `nodes = []`), rebuild. Account is removed. |
| **Rotate a key** | Replace their `.keys` file, rebuild. Old key immediately invalid. |
| **Emergency revoke** | SSH in as admin, edit `/etc/ssh/authorized_keys.d/<user>`. Overwritten on next rebuild — fix in Nix ASAP. |

## Multi-Node

The `nodes` field in the roster already handles this:

```nix
{ name = "alice"; role = "ops"; nodes = [ "server" "edge-1" ]; }
```

Each host imports `modules/users/` from the shared flake. `config.networking.hostName` filters the roster to produce the correct user set per node.

If per-node role overrides are ever needed (e.g., alice is admin on server but ops on edge-1), the roster structure can be extended — but don't build this until it's needed.

## Secrets Model

No changes needed. All sops secrets stay `owner = "root"`, consumed by systemd services. Human SSH users never touch sops files on the server.

Adding someone as a sops recipient (in `.sops.yaml`) is only needed for people who edit `secrets/secrets.yaml` on their dev machine — an admin function, separate from SSH access.

## SSH Hardening Additions

```nix
# modules/ssh.nix
services.openssh.settings.LogLevel = "VERBOSE";
```

Logs key fingerprint per login, which maps back to which person authenticated. Sudo logging is already enabled by default in NixOS.

## Changes to Existing Files

| File | Change |
|------|--------|
| `configuration.nix` | Add `./modules/users` import |
| `modules/base.nix` | Remove Tim's personal SSH key from `deploy` authorized_keys. Keep `deploy` as CI-only service account with GitHub Actions key. Keep deploy's sudo rules (or move to users module). |
| `modules/ssh.nix` | Add `LogLevel = "VERBOSE"` |

## Implementation Order

### Phase 1 — Foundation (single server)

1. Create `modules/users/roles.nix` with role definitions
2. Create `modules/users/keys/tim.keys` with Tim's ed25519 public key
3. Create `modules/users/default.nix` with roster (tim as admin) + user/sudo generation
4. Update `configuration.nix` to import `./modules/users`
5. Refactor `modules/base.nix` — remove Tim's key from deploy, keep deploy as CI-only
6. Add `LogLevel = "VERBOSE"` to `modules/ssh.nix`
7. Verify: `nixos-rebuild build`, then `ssh tim@192.168.1.7`

### Phase 2 — First team member

8. Collect their public key, add to `keys/<name>.keys`
9. Add roster entry, rebuild, verify

### Phase 3 — Multi-node (when WireGuard mesh is ready)

10. Restructure flake for multiple hosts
11. Ensure `modules/users/` is imported by all hosts
12. Verify node-filtered users work correctly

### Phase 4 — Hardening

13. Generate `AllowUsers` directive from roster
14. Restrict `tee` and `mkdir` sudo to specific paths
15. Optionally add `auditd` rules for sensitive path access

## Open Questions

- **sudo tee/mkdir scoping**: Current deploy user has `sudo tee *` and `sudo mkdir *` which can write anywhere. Should admin role inherit this, or should we restrict to specific directories (e.g., `/var/lib/deploy/*`)?
- **admin postgres access**: Current deploy user can `sudo -u postgres` anything. Should named admin users inherit this, or should it stay deploy-only for CI/CD?
- **Per-node roles**: Start simple (one role per person globally) or build the per-node override structure now?
