# Family Archive — Render → Home Server Cutover

Runbook for moving the Rails family-archive app off Render and onto this
server. Three phases, each independently rollback-able:

1. **Server prep** — upgrade Postgres to 17, destroy the Adonis-era database,
   rework the app module for Rails.
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
newer-version dump into an older server. Upgrading is cleaner and lupin
benefits too.

Every database on this server is small, so dump/restore beats `pg_upgrade`:
fewer moving parts, and it is the same procedure the backups already use.
All app containers go down for the duration (minutes).

**Config changes (`modules/postgresql.nix`, `modules/backups.nix`):**

```nix
# postgresql.nix
package = pkgs.postgresql_17;

# backups.nix — stop hard-pinning the client version
${config.services.postgresql.package}/bin/pg_dump ...
```

NixOS puts the new cluster at `/var/lib/postgresql/17`; the 16 data dir stays
on disk until you delete it, which is the rollback.

**Procedure (on the server):**

```bash
# 1. Stop everything that talks to Postgres
sudo systemctl stop docker-home-cooking docker-lupin-api-production \
  docker-lupin-api-staging docker-healthchecks pgbouncer

# 2. Dump each app DB with the *current* 16 binaries
sudo -u postgres mkdir -p /var/lib/postgresql/pre17
for db in home_cooking healthchecks lupin_production lupin_staging; do
  sudo -u postgres pg_dump -Fc "$db" -f /var/lib/postgresql/pre17/$db.dump
done
# family_archive is deliberately not in that list — see 1b.

# 3. Apply the config. postgresql.service starts a fresh 17 cluster and
#    ensureDatabases/ensureUsers recreate every role and empty database.
#    db-passwords re-applies passwords from sops.
sudo nixos-rebuild switch --flake ~/nixos-server#server --impure

# 4. Restore into the ensured databases, owned by each app user
for pair in home_cooking:home_cooking healthchecks:healthchecks \
            lupin_production:lupin_production lupin_staging:lupin_staging; do
  db=${pair%%:*}; role=${pair##*:}
  sudo -u postgres pg_restore --no-owner --no-privileges --role="$role" \
    -d "$db" /var/lib/postgresql/pre17/$db.dump
done

# 5. Bring the apps back and check them
sudo systemctl start pgbouncer docker-home-cooking docker-lupin-api-production \
  docker-lupin-api-staging docker-healthchecks
./scripts/health-check.sh
```

**Rollback:** revert the two nix changes, `nixos-rebuild switch`, and the 16
cluster is exactly where you left it. Once 17 has run clean for a week:
`sudo rm -rf /var/lib/postgresql/16 /var/lib/postgresql/pre17`.

### 1b. Destroy the Adonis database

Not dumped in 1a, so the fresh 17 cluster already has an **empty**
`family_archive` database owned by `family_archive`. Nothing else to do. The
nightly GPG backups of the old DB age out of `/var/backups/postgresql` in 30
days; delete them sooner if you want (`rm /var/backups/postgresql/family_archive-*`).

### 1c. Remove Redis from the app

Rails does not use Redis yet (see "Later" below).

- `modules/redis.nix`: comment out the `family-archive` entry in the ACL
  user list (it comes back with Sidekiq).
- `modules/secrets.nix` + `secrets/secrets.yaml`: delete
  `family-archive/redis-password` and `family-archive/app-key`.
- `apps/personal/family-archive.nix`: drop `redis-queue.service` from
  `after`, drop the `REDIS_URL` line, drop the comment about BullMQ.

The Redis instances themselves stay up, idle, for the Sidekiq move.

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
# Laptop. Render → Dashboard → family-archive-db → External Database URL.
# Needs a 17 client: brew install postgresql@17, or
#   docker run --rm postgres:17-alpine pg_dump "$URL" ...
pg_dump "$RENDER_EXTERNAL_URL" \
  --no-owner --no-privileges --format=custom \
  --exclude-table='solid_*' \
  -f family_archive.dump
scp family_archive.dump deploy@192.168.1.7:/tmp/

# Server. Wipe whatever a previous rehearsal left behind, restore as the app user.
sudo -u postgres psql -d family_archive -c \
  "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION family_archive;"
sudo -u postgres pg_restore --no-owner --no-privileges --role=family_archive \
  -d family_archive /tmp/family_archive.dump

# Deploy the Rails image (first time: push a build by hand, see FAMILY-ARCHIVE-SETUP.md §8)
./scripts/deploy.sh family-archive sha256:<digest>
docker logs family-archive 2>&1 | head -40   # db:prepare should report nothing pending
```

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

---

## Phase 3 — Cutover (≈10 min downtime)

The only writer is the admin, so "freeze writes" means don't use the admin.

1. **Suspend** the Render web service (Dashboard → Settings → Suspend). No
   request lands after the dump, and no job is mid-flight.
2. **Dump and restore** exactly as in Phase 2.
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
