# Family Archive — Render → Home Server Cutover

Runbook for moving the Rails family-archive app off Render and onto this
server. Three phases, each independently rollback-able:

1. **Server prep** — upgrade Postgres to 17 (fresh cluster, nothing on the
   old one is worth keeping), rework the app module for Rails.
2. **Rehearsal** — restore a live Render dump and run the Rails image against
   it with DNS still pointing at Render.
3. **Cutover** — freeze Render, final dump, flip Cloudflare.

Nothing from the AdonisJS deployment carries over. Its database is dropped,
not migrated. S3 is untouched: the Rails app already writes to the same
bucket under the `production/` prefix and blob keys live in the Rails DB.

---

## Phase 1 — Server prep

### 1a. Postgres 16 → 17

Render runs 17. `pg_dump` 16 refuses to connect to a 17 server, so staying on
16 would mean dumping from a laptop with a 17 client and restoring a
newer-version dump into an older server. Upgrading is cleaner.

Nothing in the 16 cluster needs to survive: lupin is a job queue, healthchecks
is lupin's heartbeat monitor, home-cooking is being reworked, and the
family-archive database is the Adonis app's. So there is no data migration.

**Config changes (`modules/postgresql.nix`, `modules/backups.nix`):**

```nix
# postgresql.nix
package = pkgs.postgresql_17;

# backups.nix — stop hard-pinning the client version
${config.services.postgresql.package}/bin/pg_dump ...
```

**Procedure (on the server):**

```bash
sudo nixos-rebuild switch --flake ~/nixos-server#server --impure
```

NixOS starts a fresh 17 cluster at `/var/lib/postgresql/17`;
`ensureDatabases`/`ensureUsers` recreate every role and empty database and
`db-passwords` re-applies the sops passwords. Each app runs its own migrations
on next boot. Check with `./scripts/health-check.sh`.

The 16 data dir stays on disk untouched. Once 17 is running:
`sudo rm -rf /var/lib/postgresql/16`.

### 1b. Destroy the Adonis database

The fresh 17 cluster already has an **empty** `family_archive` database owned
by `family_archive`. Nothing else to do. The
nightly GPG backups of the old DB age out of `/var/backups/postgresql` in 30
days; delete them sooner if you want (`rm /var/backups/postgresql/family_archive-*`).

### 1c. Remove Redis from the app

Rails does not use Redis yet (see "Later" below).

- `apps/personal/family-archive.nix`: drop `redis-queue.service` from
  `after`, drop the `REDIS_URL` line, drop the comment about BullMQ.
- `modules/secrets.nix` + `secrets/secrets.yaml`: `family-archive/app-key`
  becomes `family-archive/secret-key-base` (same value is fine).

The Redis instances, the `family_archive` ACL user and its password all stay
as they are, idle, so the Sidekiq move only has to put `REDIS_URL` back.

### 1d. Rework `apps/personal/family-archive.nix` for Rails

| Setting | Adonis | Rails |
|---|---|---|
| `appPort` | `8080` | `80` (Thruster) |
| `environment` | `NODE_ENV`, `HOST`, `PORT`, `SESSION_DRIVER`, `APP_URL`, `DRIVE_DISK` | `RAILS_ENV=production`, `APP_HOST=mariasfamilyarchive.com`, `RAILS_MAX_THREADS=3`, `WEB_CONCURRENCY=2`, `SOLID_QUEUE_IN_PUMA=true`, `JOB_CONCURRENCY=1`, `AWS_S3_KEY_PREFIX=production`, `TZ=UTC` |
| env file | `APP_KEY`, `REDIS_URL`, `S3_BUCKET` | `SECRET_KEY_BASE`, `AWS_S3_BUCKET` (rename), optional `POSTMARK_API_TOKEN` + `MAILER_SENDER` |
| volumes | none | `family-archive-storage:/rails/storage` (SQLite files for Solid Cache/Queue/Cable) |

`DATABASE_URL`, `ADMIN_*`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` are unchanged.

New sops keys: `family-archive/secret-key-base`. **Copy the value from
Render's env** (Dashboard → family-archive → Environment) so sessions and
Devise reset tokens keep verifying. If Render will not show it, generate one
with `openssl rand -hex 64` and accept that everyone is logged out once.

### 1e. Traefik CSP

`secure-headers-family-archive` in `modules/traefik.nix` was written for the
Adonis UI. The Rails public pages load Lora and Inter from Google Fonts, so:

- `style-src` add `https://fonts.googleapis.com`
- `font-src` add `https://fonts.gstatic.com`

Active Storage redirects image requests to presigned S3 URLs and the browser
checks the final URL against `img-src`/`media-src`, so the bucket origin stays.
Confirm the bucket name and region in that string match Render's
`AWS_S3_BUCKET`/`AWS_REGION`.

### 1f. Rails repo changes (`~/projects/family_archive`)

**Solid stack onto SQLite.** The Solid tables currently live in the primary
Postgres schema. Move them to per-concern SQLite files so the Postgres dump
carries only domain data:

1. `Gemfile`: add `gem "sqlite3"`.
2. `bin/rails solid_cache:install solid_queue:install solid_cable:install`
   regenerates `db/cache_schema.rb`, `db/queue_schema.rb`, `db/cable_schema.rb`
   and points `config/cache.yml`, `queue.yml`, `cable.yml` at
   `database: cache|queue|cable`. Check the diff against the existing
   polling/retention settings and keep ours.
3. `config/database.yml`: production becomes multi-db — `primary` from
   `DATABASE_URL`, plus `cache`/`queue`/`cable` as
   `adapter: sqlite3, database: storage/<name>.sqlite3` with
   `migrations_paths: db/<name>_migrate`. Do the same for development so
   `bin/dev` and the Mission Control dashboard keep working.
4. Migration: `drop_table` the eleven `solid_*` tables from the primary DB.
5. PgBouncer transaction pooling: add to the production primary
   `advisory_locks: false` (Rails' migration lock spans sessions) and
   `prepared_statements: false` (avoids caring about PgBouncer's
   `max_prepared_statements`).
6. `.github/workflows/deploy.yml`: copy from `~/projects/family-archive`
   (the Adonis repo). Builds `ghcr.io/timothyjamesmarias/family-archive`,
   SSHes in, runs `scripts/deploy.sh family-archive <digest>`. Add
   `SERVER_HOST`, `SERVER_USER`, `SERVER_SSH_KEY` to the new repo's secrets.
   Also fix `ci.yml`: it triggers on `main` but the branch is `master`.
7. `/up` is the health endpoint. `scripts/deploy.sh` probes `/health` and
   only warns, so either ignore the warning or teach the script to read the
   path from the app file.

Leave `render.yaml` and the `RENDER_EXTERNAL_HOSTNAME` fallbacks until Render
is deleted (Phase 3, step 7).

---

## Phase 2 — Rehearsal (no downtime)

Everything here runs against live Render data while Render keeps serving.
Repeat until it is boring.

```bash
# All on the server: it has the Postgres 17 client, so no laptop or scp.
# Render → Dashboard → family-archive-db → External Database URL. Render
# requires SSL; a laptop pg_dump without ?sslmode=require (or with a 16
# client) fails.
ssh nix-server
read -r URL   # paste the external URL, so it stays out of shell history
pg_dump "${URL}?sslmode=require" --no-owner --no-privileges --format=custom \
  --exclude-table='solid_*' -f /tmp/family_archive.dump

# Wipe whatever a previous rehearsal (or db:prepare) left behind, restore as
# the app user so every table lands owned by family_archive.
sudo systemctl stop docker-family-archive
sudo -u postgres psql -d family_archive -c \
  "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION family_archive;"
sudo -u postgres pg_restore --no-owner --no-privileges --role=family_archive \
  -d family_archive /tmp/family_archive.dump
sudo systemctl start docker-family-archive
docker logs family-archive 2>&1 | grep -iE "migrat|aborted"   # expect the
# solid-tables migration to run (the dump excludes them), nothing else.
```

The Rails image is deployed by the GitHub workflow on every push to
`master`; the first deploy already happened, so no manual image push.

Checks that can run from the server, with the real Host header against
Traefik (`-H "Host: mariasfamilyarchive.com" https://127.0.0.1/...`):
`/up`, `/`, `/family-tree`, `/login` and `/sitemap.xml` return 200; an
`/rails/active_storage/representations/redirect/...` URL from `/artifacts`
302s to the S3 bucket and the object returns 200.

Verify without touching DNS. On the laptop add
`192.168.1.7 mariasfamilyarchive.com` to `/etc/hosts`, then:

- Home page renders with Lora/Inter (fonts = CSP is right).
- Log in with the admin account (session secret is right).
- Open an artifact; thumbnails load (S3 read + `img-src`).
- Upload a test file; `/admin/jobs` shows the transform job completing
  (S3 write + Solid Queue on SQLite + libvips in the image).
- Edit something in the family tree (writes through PgBouncer).

Remove the hosts entry. The test upload lands under `production/` in S3 and in
the rehearsal DB; it is overwritten by the Phase 3 restore, so delete the S3
object by hand or ignore the orphan.

Gotchas met during the first rehearsal, already fixed on the server:

- `db-passwords` and `pgbouncer-auth` had `requires = sops-nix.service`, a
  unit that does not exist, so they never ran against the new cluster (no
  app passwords, no `pgbouncer` role). Fixed in `modules/postgresql.nix`.
- The `family-archive-storage` volume was created while the Adonis image was
  still pinned, so Docker made it an empty root-owned directory and the
  Rails process (uid 1000) could not create its SQLite files. One-off
  `chown 1000:1000` on the volume. A volume first mounted by the Rails image
  inherits `/rails/storage`'s ownership and does not have this problem.
- `db:prepare` only seeds when it creates the database, and NixOS creates
  it first, so a fresh server DB has no admin user. Irrelevant once the
  Render data is restored.
- The GHCR package `family-archive` was linked to the Adonis repo; the new
  repo's workflow needed Write under the package's "Manage Actions access".

---

## Phase 3 — Cutover (≈10 min downtime)

The only writer is the admin, so "freeze writes" means don't use the admin.

1. **Suspend** the Render web service (Dashboard → Settings → Suspend). No
   request lands after the dump, and no job is mid-flight.
2. **Dump and restore** exactly as in Phase 2 (all on the server, ~1 min).
3. `sudo systemctl restart docker-family-archive` so connections are fresh,
   then re-run the `/etc/hosts` checks.
4. **Cloudflare**: change the `mariasfamilyarchive.com` record from Render's
   CNAME to an A record → `192.168.1.7`, proxied. Proxied records switch at
   the edge immediately, no TTL wait. Same for `www` if present.
5. `curl -I https://mariasfamilyarchive.com/up` → 200. `./scripts/health-check.sh` green.
6. Leave Render suspended for a week.
7. Delete the Render service and database. Then in the Rails repo delete
   `render.yaml` and the `RENDER_EXTERNAL_HOSTNAME` fallbacks in
   `config/environments/production.rb`.

**Rollback** (any time before step 7): flip the Cloudflare record back and
unsuspend Render. Admin edits made on the home server after the flip would be
lost, so do none until you are confident.

---

## Later: Sidekiq + Redis

SQLite-backed Solid Queue/Cache/Cable is the stopgap. The server already runs
a Redis `queue` instance (noeviction + AOF, backed up nightly) and a `cache`
instance (allkeys-lru). When ready:

1. Re-register `family-archive` in `modules/redis.nix` and restore the
   `redis-password` secret; `REDIS_URL` goes back into the env file, pointed
   at port 6380 (queue). Cache can use 6379.
2. Rails: `gem "sidekiq"`, `config.active_job.queue_adapter = :sidekiq`,
   `config.cache_store = :redis_cache_store`, `cable.yml` adapter `redis`.
   Drop `solid_*` gems, `SOLID_QUEUE_IN_PUMA`, the SQLite databases, and the
   `storage` volume. Mount Sidekiq's web UI where Mission Control was.
3. Sidekiq needs its own process. Either a second container in the nix file
   running `bundle exec sidekiq` on the same image, or the `sidekiq` Puma
   plugin if one process is still enough.
