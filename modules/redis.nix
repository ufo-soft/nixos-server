{ config, pkgs, lib, ... }:

let
  # Central Redis app registry.
  # Add one entry per app that needs cache and/or queue access.
  # Each gets an ACL user scoped to its own key prefix on each instance.
  #
  # `name` matches the app name used elsewhere (kebab-case, matches apps/<ns>/<name>.nix).
  # `user` is the ACL username (snake_case, mirrors postgresql.nix convention).
  # `prefix` is the key namespace the app is allowed to touch.
  redisApps = [
    # NOTE: `prefix` is load-bearing on the app side too — the generated ACL
    # confines the user to `<prefix>:*` keys AND channels, so BullMQ must be
    # constructed with a matching `prefix` option (its default is `bull`).
    { name = "family-archive"; user = "family_archive"; prefix = "family-archive"; }
    # { name = "home-cooking"; user = "home_cooking"; prefix = "home-cooking"; }
  ];

  # Docker bridge gateway — containers reach host services via this address.
  # Must match the listen address apps use for host.docker.internal.
  dockerGateway = "172.17.0.1";

  cachePort = 6379;
  queuePort = 6380;

  # Build the ACL rule line for one app on one instance.
  #
  # Rules, in order:
  #   on                  — user is enabled
  #   >PASSWORD           — plaintext password (Redis hashes it internally)
  #   ~<prefix>:*         — may only touch keys under its own prefix
  #   &<prefix>:*         — may only use pub/sub channels under its own prefix
  #   +@all -@dangerous   — all commands except the dangerous set
  #                         (-@dangerous removes FLUSHALL, CONFIG, SHUTDOWN,
  #                          KEYS, DEBUG, REPLICAOF, ACL, etc.)
  #   +info               — see below
  #
  # NOTE: -@dangerous also removes CLUSTER, MIGRATE, and RESTORE. If an app
  # ever needs one of those, add it back explicitly (+command) rather than
  # dropping the -@dangerous rule wholesale.
  #
  # WHY +info: INFO is in @dangerous, but BullMQ issues INFO on every connection
  # to detect the server version. Without this exception the client fails at
  # connect time — before any job is enqueued — with
  #   "NOPERM User <u> has no permissions to run the 'info' command"
  # Verified against Redis 8.8 with this exact rule: EVAL, EVALSHA, SCRIPT and
  # CLIENT are NOT in @dangerous (so BullMQ's Lua works unaided), but INFO is.
  # KEYS stays denied — BullMQ uses SCAN, never KEYS.
  mkAclUser = app: password:
    "user ${app.user} on >${password} ~${app.prefix}:* &${app.prefix}:* +@all -@dangerous +info";

  # Generate the ACL file for an instance from the app registry.
  # Passwords are read from sops at runtime, so this is a script that emits
  # the file rather than a Nix-built static file — secrets must never land
  # in the world-readable Nix store.
  #
  # IMPORTANT: this runs as an ExecStartPre on the redis unit itself, with a
  # "+" prefix (root, outside the sandbox), NOT as a separate oneshot.
  #
  # The reason: the NixOS redis module sets `RuntimeDirectory = redis-<name>`,
  # and systemd DELETES AND RECREATES that directory every time the unit
  # starts (RuntimeDirectoryPreserve defaults to "no"). A separate service
  # writing /run/redis-<name>/users.acl beforehand would have its file wiped
  # the moment redis started — and since redis refuses to boot when `aclfile`
  # points at a missing file, the instance would fail to start entirely.
  #
  # ExecStartPre runs after systemd has created the RuntimeDirectory but
  # before redis-server executes, which is the only correct window. This
  # mirrors how the module's own ExecStartPre handles requirePassFile.
  mkAclScript = instance: pkgs.writeShellScript "redis-${instance}-acl" ''
    set -euo pipefail
    ACL_FILE="/run/redis-${instance}/users.acl"

    # default user is disabled — every client must authenticate as an app user.
    #
    # NOTE: because this file defines `default`, requirePass must NOT be set
    # on these instances. Redis refuses to load an ACL file that redefines a
    # user requirepass has already configured.
    {
      echo "user default off"
    ${lib.concatMapStringsSep "\n" (app: ''
      PASS_${lib.replaceStrings ["-"] ["_"] app.name}="$(cat ${config.sops.secrets."${app.name}/redis-password".path})"
      echo "${mkAclUser app "\${PASS_${lib.replaceStrings ["-"] ["_"] app.name}}"}"
    '') redisApps}
    } > "$ACL_FILE"

    # UMask=0077 on the unit means the file is already tight; set ownership
    # explicitly so redis-server (running as redis-<instance>, unprivileged)
    # can read what root just wrote.
    chmod 640 "$ACL_FILE"
    chown redis-${instance}:redis-${instance} "$ACL_FILE"
    echo "Wrote ACL file for redis-${instance} (${toString (builtins.length redisApps)} app users)"
  '';
in
{
  # ==========================================================================
  # Redis — two instances with deliberately different durability contracts.
  #
  #   cache (6379) — evictable, ephemeral. Backs Rails cache + Action Cable
  #                  pub/sub. Everything here is regenerable. Never backed up.
  #
  #   queue (6380) — durable, never evicts. Backs job queues. Losing a key
  #                  here means losing a job, so eviction is disabled and
  #                  AOF is on. Backed up by redis-backup.service.
  #
  # These two policies are mutually exclusive in one instance, which is the
  # whole reason for the split: allkeys-lru silently dropping a queued job is
  # data loss, while noeviction on a cache turns a full cache into write
  # failures. Sharing one instance means picking a policy that is wrong for
  # one of the two workloads.
  # ==========================================================================

  services.redis.servers = {
    # --- cache: ephemeral, evictable ---
    cache = {
      enable = true;
      port = cachePort;
      bind = "127.0.0.1 ${dockerGateway}";

      # No persistence. Nothing here survives a restart, by design.
      save = [];
      appendOnly = false;

      settings = {
        maxmemory = "256mb";
        maxmemory-policy = "allkeys-lru";

        # ACL file is generated at runtime from sops secrets.
        aclfile = "/run/redis-cache/users.acl";

        # Keep pub/sub clients from being killed under buffer pressure.
        # Action Cable fan-out can burst; 32mb hard / 8mb soft over 60s is
        # the Redis default for pubsub and is fine here, but stated
        # explicitly so it is not silently inherited.
        #
        # A list, not a string: redis takes one client-output-buffer-limit
        # directive per class, and the module renders list elements as
        # repeated keys (listsAsDuplicateKeys).
        client-output-buffer-limit = [ "pubsub 32mb 8mb 60" ];
      };
    };

    # --- queue: durable, never evicts ---
    queue = {
      enable = true;
      port = queuePort;
      bind = "127.0.0.1 ${dockerGateway}";

      # AOF with per-second fsync. Worst case on hard power loss is ~1s of
      # enqueues, which is the standard durability/throughput trade.
      # RDB snapshots also kept — redis-backup.service copies the RDB.
      appendOnly = true;
      save = [ [ 900 1 ] [ 300 10 ] [ 60 10000 ] ];

      settings = {
        maxmemory = "512mb";

        # noeviction: when full, writes fail loudly rather than silently
        # dropping jobs. A failed enqueue is recoverable; a vanished job
        # is not.
        maxmemory-policy = "noeviction";

        appendfsync = "everysec";

        aclfile = "/run/redis-queue/users.acl";
      };
    };
  };

  # Generate each instance's ACL file from sops secrets, as an ExecStartPre on
  # the redis unit itself. The "+" prefix runs it as root outside the service
  # sandbox — necessary both to read the sops secret and to write into the
  # RuntimeDirectory systemd has just created. See mkAclScript for why this
  # cannot be a separate service.
  # mkAfter: the redis module defines its own ExecStartPre (for requirePassFile).
  # A bare assignment would be a merge conflict; this appends to whatever the
  # module already set, and ordering after it is correct — the ACL file only
  # needs to exist before redis-server itself execs.
  #
  # `after` only, never `requires`: sops-nix installs secrets from an activation
  # script, not a unit, so "sops-nix.service" does not exist on this system. A
  # non-existent unit in `after` is an inert no-op, but in `requires` it is a
  # hard dependency that systemd cannot satisfy — the instance then fails with
  # "Unit sops-nix.service not found" and takes redis-backup.timer down with it.
  # Every other module here uses bare `after` for the same reason.
  #
  # Ordering is belt-and-braces regardless: the activation script has already
  # written the secrets by the time any unit starts.
  systemd.services.redis-cache = {
    after = [ "sops-nix.service" ];
    serviceConfig.ExecStartPre = lib.mkAfter [ "+${mkAclScript "cache"}" ];
  };

  systemd.services.redis-queue = {
    after = [ "sops-nix.service" ];
    serviceConfig.ExecStartPre = lib.mkAfter [ "+${mkAclScript "queue"}" ];
  };

  # Redis must be reachable from containers but never from the LAN or WAN.
  # The bind above already restricts to loopback + docker gateway; firewall.nix
  # adds the matching iptables ACCEPT for the Docker subnet.
}
