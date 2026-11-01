# Family Archive — First-Time Setup

Step-by-step runbook for deploying the family-archive app from scratch. Do these
in order. For moving an existing deployment onto this server see
`FAMILY-ARCHIVE-CUTOVER.md`.

## 1. Cloudflare — Domain Setup

Add `mariasfamilyarchive.com` to Cloudflare and configure DNS.

1. Log into Cloudflare > Add a site > `mariasfamilyarchive.com`
2. Select the Free plan
3. Update the domain's nameservers at your registrar to the ones Cloudflare gives you
4. Wait for nameserver propagation (can take up to 24 hours, usually minutes)
5. Create DNS records:
   - **A record**: `mariasfamilyarchive.com` → `192.168.1.7` (Proxied / orange cloud)
   - **A record**: `www.mariasfamilyarchive.com` → `192.168.1.7` (Proxied) — optional, for www redirect
6. Set SSL/TLS mode to **Full (strict)**

### Cloudflare API Token

Your existing Cloudflare API token needs DNS edit permissions for this new zone. If it's scoped to `timothymarias.com` only, you'll need to update it:

1. Go to Cloudflare > My Profile > API Tokens
2. Edit your existing token
3. Under Zone Resources, add `mariasfamilyarchive.com` (or change to "All zones")
4. Save

The DDNS updater in `cloudflare-ddns.nix` will also need to know about this zone if you want automatic IP updates for it.

## 2. Cloudflare — Origin CA Certificate

Generate an origin certificate so Traefik can terminate TLS from Cloudflare.

1. In Cloudflare, go to `mariasfamilyarchive.com` > SSL/TLS > Origin Server
2. Click "Create Certificate"
3. Let Cloudflare generate a private key (RSA or ECDSA)
4. Hostnames: `mariasfamilyarchive.com`, `*.mariasfamilyarchive.com`
5. Validity: 15 years (default)
6. Click Create
7. **Copy the certificate (PEM)** — you'll need this for secrets
8. **Copy the private key** — you'll need this for secrets
9. You cannot retrieve the private key later, so save it now

## 3. AWS — S3 Bucket and IAM User

Create a dedicated S3 bucket and scoped IAM credentials.

### Create the bucket

1. Go to AWS Console > S3 > Create bucket
2. Bucket name: something like `marias-family-archive` (globally unique)
3. Region: pick one close to your server (e.g., `us-east-1`)
4. Block all public access: **uncheck this** — the app serves images via direct public S3 URLs (`https://BUCKET.s3.REGION.amazonaws.com/PATH`), so objects need to be publicly readable
5. Create bucket

Add this bucket policy (Bucket > Permissions > Bucket policy) to allow public reads:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

### Create IAM user

1. Go to IAM > Users > Create user
2. Name: `family-archive-s3`
3. No console access needed
4. Attach an inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }
  ]
}
```

5. Create the user, then create an access key (use case: "Application running outside AWS")
6. Save the Access Key ID and Secret Access Key — you'll need them for secrets

## 4. GitHub Container Registry (GHCR)

The server pulls Docker images from GHCR. It needs a Personal Access Token to authenticate.

### Create the token

1. Go to GitHub > Settings > Developer settings > Personal access tokens > **Tokens (classic)**
2. Click "Generate new token" > "Generate new token (classic)"
3. Name: `nixos-server-ghcr` (or similar)
4. Expiration: pick something reasonable (90 days, or no expiration if you prefer)
5. Select scopes:
   - `read:packages` — pull images from GHCR
   - `write:packages` — push images to GHCR (needed by CI)
6. Generate token and copy it

**Important**: use a classic token, not a fine-grained one. Fine-grained tokens don't support GHCR.

### Add to secrets

The token goes into `ghcr-token` in `secrets/secrets.yaml` (see next step). The server's `docker-ghcr-login` systemd service uses it to log into GHCR at boot.

### Verify (after deploying secrets)

```bash
sudo cat /run/secrets/ghcr-token | docker login ghcr.io -u timothyjamesmarias --password-stdin
```

You should see `Login Succeeded`. If not, check the token scopes and that there's no trailing whitespace.

## 5. Secrets — sops-nix

Add all secrets to the encrypted secrets file.

```bash
cd ~/projects/nixos-server
sops secrets/secrets.yaml
```

Add these entries:

```yaml
# Origin CA certificate for mariasfamilyarchive.com
origin-cert-pem-familyarchive: |
    -----BEGIN CERTIFICATE-----
    <paste the certificate from step 2>
    -----END CERTIFICATE-----
origin-cert-key-familyarchive: |
    -----BEGIN PRIVATE KEY-----
    <paste the private key from step 2>
    -----END PRIVATE KEY-----

# Family Archive app secrets
family-archive:
    secret-key-base: <copy from Render, or generate: openssl rand -hex 64>
    admin-email: <your email address>
    admin-password: <your admin password>
    admin-name: <display name for the admin account>
    database-password: <generate: openssl rand -hex 16>
    s3-bucket: <bucket name from step 3>
    s3-region: <e.g., us-east-1>
    aws-access-key-id: <from step 3>
    aws-secret-access-key: <from step 3>
```

Save and close — sops encrypts automatically.

## 6. Database — Set User Password

NixOS `ensureDatabases` and `ensureUsers` will create the database and user, but you need to set the password manually (NixOS doesn't manage postgres passwords declaratively).

After the first `nixos-rebuild switch` that includes the family-archive config:

```bash
# On the server
sudo -u postgres psql -c "ALTER USER family_archive WITH PASSWORD '<same password from sops>';"
```

The password must match what you put in `family-archive/database-password` in secrets.yaml, because the env file generator constructs the `DATABASE_URL` with it.

### PgBouncer auth file

After setting the password, regenerate the PgBouncer auth file so it picks up the new credentials:

```bash
sudo systemctl restart pgbouncer-auth
sudo systemctl restart pgbouncer
```

The `pgbouncer-auth` service extracts SCRAM password hashes from `pg_shadow` into `/run/pgbouncer-auth/userlist.txt`. PgBouncer reads this file to authenticate client connections. This must be rerun any time you change a database user's password.

**Important:** The auth file lives in `/run/pgbouncer-auth/`, not `/run/pgbouncer/`. PgBouncer owns `/run/pgbouncer/` for its socket — using the same directory causes systemd to wipe one service's files when the other restarts.

## 7. GitHub — CI Deploy Key

Generate an SSH key pair for GitHub Actions to use when deploying.

```bash
# On your local machine
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_actions_deploy -N ""
```

Add the **public key** to the deploy user's authorized keys in `modules/base.nix`:

```nix
users.users.deploy = {
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3... timmarias@Tims-MacBook-Pro.local"
    "ssh-ed25519 AAAAC3... github-actions-deploy"  # <-- add this
  ];
};
```

Add the **private key** as a GitHub repo secret:

1. Go to familyArchive repo > Settings > Secrets and variables > Actions
2. Add these repository secrets:
   - `SERVER_SSH_KEY`: paste the contents of `~/.ssh/github_actions_deploy`
   - `SERVER_HOST`: your server's public IP (or DDNS hostname like `server.timothymarias.com`)
   - `SERVER_USER`: `deploy`

### Router port forwarding

GitHub Actions needs to SSH into your server, so port 22 must be forwarded on your router. Forward external port 22 → `192.168.1.7:22` (TCP). On the Netgear router, access `http://192.168.1.1/start.htm` > Advanced > Advanced Setup > Port Forwarding.

## 8. Deploy

With all the above in place:

```bash
# On your local machine, push the nixos-server changes
cd ~/projects/nixos-server
git add -A && git commit -m "feat: add family-archive app"
git push

# SSH into the server and apply
ssh deploy@<server-ip>
cd ~/nixos-server
git pull
sudo nixos-rebuild switch --flake ~/nixos-server#server
```

Then set the database password (step 6 above).

For the first app deployment, you can either:
- Create a GitHub release on familyArchive (triggers the full pipeline), or
- Build and push the image manually, then run `deploy.sh`:

```bash
# Manual first deploy (from your local machine)
docker build -t ghcr.io/timothyjamesmarias/family-archive:v0.1.0 .
docker push ghcr.io/timothyjamesmarias/family-archive:v0.1.0

# Get the digest
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/timothyjamesmarias/family-archive:v0.1.0 | cut -d@ -f2

# On the server
./scripts/deploy.sh family-archive sha256:<digest>
```

## 9. Verify

```bash
# On the server — check container is running and healthy
docker ps --filter name=family-archive

# Check logs for migration output
docker logs family-archive 2>&1 | head -20

# From anywhere — test the endpoint
curl -I https://mariasfamilyarchive.com/
```

You should see a 200 response. Log in at `https://mariasfamilyarchive.com/login` with the admin email and password from your secrets.

## Troubleshooting

### Container won't start
```bash
# Check systemd service status
sudo systemctl status docker-family-archive

# Check if env file was generated
sudo cat /run/family-archive/env

# Check if sops secrets were decrypted
sudo ls -la /run/secrets/family-archive/
```

### Database connection refused / SASL auth failed
```bash
# Verify PgBouncer is listening on the Docker bridge
ss -tlnp | grep 6432

# Test direct PostgreSQL connection (bypass PgBouncer)
PGPASSWORD='<password>' psql -h 127.0.0.1 -p 5432 -U family_archive -d family_archive -c "SELECT 1;"

# Test through PgBouncer
PGPASSWORD='<password>' psql -h 127.0.0.1 -p 6432 -U family_archive -d family_archive -c "SELECT 1;"

# If direct works but PgBouncer fails, regenerate the auth file
sudo systemctl restart pgbouncer-auth
sudo systemctl restart pgbouncer

# Verify auth file has actual password hashes (not column headers)
sudo cat /run/pgbouncer-auth/userlist.txt

# Check PgBouncer logs for details
sudo journalctl -u pgbouncer --no-pager -n 20

# Check pg_hba.conf allows the Docker subnet
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE database::text LIKE '%family%';"
```

### S3 upload failures
- Verify the bucket exists and the region matches
- Verify the IAM credentials are correct: `aws s3 ls s3://BUCKET_NAME/ --region REGION`
- The container needs internet access — verify it's on `proxy-net` (not an internal network)

### Traefik 404 / middleware not found

If Traefik returns 404 or logs `middleware "X@file" does not exist`, the dynamic config file isn't being loaded.

Traefik needs both a Docker provider (for container labels) and a file provider (for middlewares and TLS certs). Verify the static config has both:

```bash
cat /etc/traefik/traefik.yml | jq '.providers'
```

You should see both `docker` and `file` entries. If `file` is missing, it was added in `modules/traefik.nix` — rebuild and restart Traefik:

```bash
sudo systemctl restart docker-traefik
```

### TLS / certificate errors
- Verify Cloudflare SSL/TLS is set to "Full (strict)"
- Verify the origin cert covers `mariasfamilyarchive.com`
- Check Traefik logs: `docker logs traefik 2>&1 | grep -i cert`
