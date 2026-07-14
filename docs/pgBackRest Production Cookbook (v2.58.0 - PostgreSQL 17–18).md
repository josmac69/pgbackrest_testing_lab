# pgBackRest Production Cookbook (v2.58.0 / PostgreSQL 17–18)

Companion operational cookbook to the pgBackRest source-level deep dive. Every recipe assumes an EXISTING, running PostgreSQL cluster. pgBackRest 2.58.0 was released **January 19, 2026** (per the official PostgreSQL.org announcement). Two release-level notes matter for this version: the minimum values for `repo-storage-upload-chunk-size` were increased to the vendor minimums, and **TLS ≥ 1.2 is now required** (relaxed only when storage TLS verification is disabled).

## Table of Contents
- **Recipe 0** — Pre-flight / Common Foundation
- **Recipe 1** — Local Repository on the DB Host
- **Recipe 2** — Dedicated Repository Host via SSH
- **Recipe 3** — Dedicated Repository Host via TLS Server
- **Recipe 4** — Direct to Object Storage (S3 / Azure / GCS)
- **Recipe 5** — Multi-Repo (local + cloud)
- **Recipe 6** — Patroni / HA Cluster Integration
- **Recipe 7** — Major Version Upgrade with stanza-upgrade
- **Recipe 8** — Operations Runbook (Day-2)

## Key cross-cutting facts (verified)
- **Local and remote pgBackRest binaries MUST be the exact same version**; mismatches raise ProtocolError. (The 2.58.0 release notes explicitly added a doc change: "Clarify requirement for local/remote pgBackRest versions to match.")
- `backup-standby` accepts `y` (standby required, fails if standby down), `prefer` (standby if available else primary; added in v2.54.0 — release note "Allow requested standby backup to proceed with no standby"), and `n` (primary only, default).
- `repo-bundle` must be enabled before `repo-block`; repo-block recommended at v2.52.1+.
- Encryption (`repo-cipher-type`/`repo-cipher-pass`) MUST be set before stanza-create and cannot be retrofitted.
- `archive-push-queue-max`: when exceeded in async mode pgBackRest DROPS the entire WAL queue and reports success to PostgreSQL — this breaks PITR.
- Default dir mode 0750, file mode 0640, lock/log 0770/0660; neutral-umask on by default.
- TLS server default port 8432; no CRL support — revoke by removing the tls-server-auth line + restart.

---

## RECIPE 0 — Pre-flight / Common Foundation

### 0.1 Installation

Debian/Ubuntu (PGDG apt):
```bash
sudo apt install -y postgresql-common ca-certificates
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo apt update
sudo apt install -y pgbackrest
pgbackrest version   # pgBackRest 2.58.0
```

RHEL/Rocky/Alma (PGDG dnf):
```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf install -y pgbackrest
pgbackrest version
```

Build from source with meson (on a build host, not production):
```bash
mkdir -p /build
wget -q -O - https://github.com/pgbackrest/pgbackrest/archive/release/2.58.0.tar.gz | tar zx -C /build
# Debian deps:
sudo apt-get install -y python3-distutils meson gcc libpq-dev libssl-dev libxml2-dev \
  pkg-config liblz4-dev libzstd-dev libbz2-dev libz-dev libyaml-dev libssh2-1-dev
# RHEL deps:
# sudo dnf install -y meson gcc postgresql17-devel openssl-devel libxml2-devel \
#   lz4-devel libzstd-devel bzip2-devel libyaml-devel libssh2-devel
meson setup /build/pgbackrest /build/pgbackrest-release-2.58.0
ninja -C /build/pgbackrest
sudo cp /build/pgbackrest/src/pgbackrest /usr/bin/
sudo chmod 755 /usr/bin/pgbackrest
```
Required libs: libbz2, liblz4 (>=1.0), libssl (>=1.1.1), libpq, libxml-2.0, libyaml-0.1, libz. Optional: libssh2 (SFTP), libzstd (>=1.0, for zst compression). Copy the single binary to production hosts — **it must match versions exactly everywhere** (this requirement is explicitly documented as of 2.58.0).

### 0.2 Inspect the existing cluster
```sql
SHOW archive_mode;      -- changing requires RESTART
SHOW archive_command;   -- changing only needs reload
SHOW wal_level;         -- must be >= replica
SHOW max_wal_senders;
```
```bash
# checksum status (offline check)
pg_checksums --check -D /var/lib/pgsql/17/data   # cluster must be stopped
# or online:
psql -Atc "SHOW data_checksums;"
```
Changing `archive_mode` requires a full restart; `archive_command` only needs `SELECT pg_reload_conf();`. Best practice on an existing cluster: enable `archive_mode=on` with a harmless placeholder command first (during your next maintenance restart, e.g. `archive_command='/bin/true'`), then switch `archive_command` to pgBackRest with a reload.

### 0.3 Directory layout, ownership, permissions
```bash
sudo mkdir -p /etc/pgbackrest/conf.d /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
sudo touch /etc/pgbackrest/pgbackrest.conf
sudo chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest/conf.d
sudo chmod 750 /var/lib/pgbackrest
sudo chmod 640 /etc/pgbackrest/pgbackrest.conf
```
Config file precedence: `/etc/pgbackrest/pgbackrest.conf`, else `/etc/pgbackrest.conf`; include files in `/etc/pgbackrest/conf.d/*.conf`.

### 0.4 Baseline pgbackrest.conf skeleton (production defaults)
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-bundle=y
repo1-block=y
compress-type=zst
compress-level=6
start-fast=y
delta=y
process-max=4                 # ~ number of CPU cores / 2 for online backup
log-level-console=info
log-level-file=detail
io-timeout=60
db-timeout=600
archive-timeout=60

[global:archive-push]
process-max=2                 # WAL push parallelism
compress-level=3              # lower level: faster archiving

[global:archive-get]
process-max=2

[global:restore]
process-max=8                 # cluster is down during restore: use more cores

[main]
pg1-path=/var/lib/pgsql/17/data
pg1-port=5432
```
Sizing guidance:
- `process-max`: online backup competes with the live server — cap around half the cores. Restore runs while PG is stopped, so use most cores.
- `compress-type=zst` recommended over default gz (much faster, similar ratio; supported since v2.27).
- `repo-bundle`/`repo-block` require newer readers — enabling them means older pgBackRest cannot read the repo.

### 0.5 PostgreSQL side
```sql
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';           -- needs restart
ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=main archive-push %p';
ALTER SYSTEM SET max_wal_senders = 10;
SELECT pg_reload_conf();                         -- applies archive_command
-- archive_mode change requires:  sudo systemctl restart postgresql-17
```
For recovery, pgBackRest auto-generates `restore_command = 'pgbackrest --stanza=main archive-get %f "%p"'` in `postgresql.auto.conf` during restore.

### 0.6 stanza-create, check, first backup
```bash
sudo -iu postgres pgbackrest --stanza=main stanza-create
sudo -iu postgres pgbackrest --stanza=main check
sudo -iu postgres pgbackrest --stanza=main --type=full backup
sudo -iu postgres pgbackrest --stanza=main info
```
Expected `info` snippet:
```
stanza: main
    status: ok
    cipher: none
    db (current)
        wal archive min/max (17): 000000010000000000000001/000000010000000000000003
        full backup: 20260714-020000F
            timestamp start/stop: 2026-07-14 02:00:00 / 2026-07-14 02:00:12
```

### 0.7 First-run troubleshooting
| Error | Cause / fix |
|---|---|
| `unable to find primary cluster` | pg1-path wrong or PG down; verify path == `data_directory`. |
| `WAL segment ... was not archived before the 60000ms timeout` | archive_command not active/reloaded, or archive_mode not restarted. Run `SELECT pg_reload_conf();`, confirm `archive_mode=on` after restart. |
| Permission errors | postgres must own/write `/var/lib/pgbackrest`, `/var/spool/pgbackrest`. |
| `raised from remote process ... version mismatch` | binaries differ across hosts — align exact versions. |
| stanza mismatch / system-id | repo was created for another cluster; use a fresh repo path or correct stanza. |

---

## RECIPE 1 — Local Repository on the DB Host

Simplest production setup; repo on same host as PostgreSQL. Not disaster-safe on its own — pair with an off-host copy (see Recipe 5).

### 1.1 Config
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=6
repo1-bundle=y
repo1-block=y
compress-type=zst
start-fast=y
delta=y
process-max=4
log-level-file=detail

[main]
pg1-path=/var/lib/pgsql/17/data
pg1-port=5432
```

### 1.2 Init
```bash
sudo -iu postgres pgbackrest --stanza=main stanza-create
sudo -iu postgres pgbackrest --stanza=main check
```

### 1.3 Schedule — systemd timers (preferred)
`/etc/systemd/system/pgbackrest-full.service`:
```ini
[Unit]
Description=pgBackRest full backup (main)
[Service]
Type=oneshot
User=postgres
ExecStart=/usr/bin/pgbackrest --stanza=main --type=full backup
```
`/etc/systemd/system/pgbackrest-full.timer`:
```ini
[Unit]
Description=Weekly pgBackRest full backup
[Timer]
OnCalendar=Sun *-*-* 02:00:00
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
```
`/etc/systemd/system/pgbackrest-diff.service` (same as full but `--type=diff`), and `pgbackrest-diff.timer`:
```ini
[Unit]
Description=Daily pgBackRest differential backup
[Timer]
OnCalendar=Mon..Sat *-*-* 02:00:00
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pgbackrest-full.timer pgbackrest-diff.timer
systemctl list-timers 'pgbackrest*'
```
`Persistent=true` runs a missed backup after boot (unlike cron); `RandomizedDelaySec` staggers fleet-wide I/O.

Cron equivalent (`crontab -u postgres -e`):
```cron
30 2 * * 0 pgbackrest --stanza=main --type=full backup
30 2 * * 1-6 pgbackrest --stanza=main --type=diff backup
```

### 1.4 Retention & the WAL trap
- `repo1-retention-full=2` — keep 2 fulls; expiration only happens when count EXCEEDS retention (the 3rd full triggers expiry of the oldest).
- `repo1-retention-diff=6` — rolling diffs; diffs only rely on the prior full.
- `repo1-retention-archive` / `repo1-retention-archive-type`: by default WAL needed to make retained backups consistent is kept automatically. Setting `repo1-retention-archive` too low aggressively expires WAL and DESTROYS PITR ability for older backups — the "WAL retention trap." Leave it unset unless you fully understand the consequences.

### 1.5 Restore drills
Full restore (cluster stopped, data dir emptied):
```bash
sudo systemctl stop postgresql-17
sudo -iu postgres pgbackrest --stanza=main restore
sudo systemctl start postgresql-17
```
Delta restore (fast — only changed files rewritten, computed via file hash):
```bash
sudo systemctl stop postgresql-17
sudo -iu postgres pgbackrest --stanza=main --delta restore
```
PITR by time:
```bash
sudo -iu postgres pgbackrest --stanza=main --delta \
  --type=time "--target=2026-07-14 09:28:56+00" --target-action=promote restore
```
Restore to a different location for test restores:
```bash
sudo -iu postgres pgbackrest --stanza=main \
  --pg1-path=/var/lib/pgsql/17/testrestore restore
```

### 1.6 Troubleshooting
- `pg_wal` filling up: archive-push failing; check `/var/log/pgbackrest/main-archive-push*.log`.
- Restore refuses: data dir not empty and `--delta`/`--force` not set.

---

## RECIPE 2 — Dedicated Repository Host via SSH

Hosts: `pg1.example.com` (DB), `repo1.example.com` (repo). Repo owned by dedicated `pgbackrest` user.

### 2.1 Create repo user + directories (on repo1)
```bash
sudo groupadd pgbackrest
sudo adduser --system --ingroup pgbackrest --shell /bin/bash pgbackrest
sudo mkdir -p /var/lib/pgbackrest /var/log/pgbackrest
sudo chown pgbackrest:pgbackrest /var/lib/pgbackrest /var/log/pgbackrest
sudo chmod 750 /var/lib/pgbackrest
```
Use a dedicated `pgbackrest` user, not `postgres`, to avoid confusion and limit accidental damage.

### 2.2 Passwordless SSH both directions
```bash
# On pg1 (as postgres):
sudo -u postgres ssh-keygen -t ed25519 -f ~postgres/.ssh/id_ed25519 -N ""
# On repo1 (as pgbackrest):
sudo -u pgbackrest ssh-keygen -t ed25519 -f ~pgbackrest/.ssh/id_ed25519 -N ""
# Exchange public keys:
#   postgres@pg1 pubkey -> ~pgbackrest/.ssh/authorized_keys on repo1
#   pgbackrest@repo1 pubkey -> ~postgres/.ssh/authorized_keys on pg1
# Verify:
sudo -u postgres ssh pgbackrest@repo1.example.com hostname
sudo -u pgbackrest ssh postgres@pg1.example.com hostname
```
SSH hardening — restrict the key in `authorized_keys`:
```
command="/usr/bin/pgbackrest",restrict ssh-ed25519 AAAA... pgbackrest@repo1
```

### 2.3 Config — repo1.example.com
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=4
repo1-bundle=y
repo1-block=y
compress-type=zst
start-fast=y
delta=y
process-max=4

[main]
pg1-host=pg1.example.com
pg1-host-user=postgres
pg1-path=/var/lib/pgsql/17/data
```

### 2.4 Config — pg1.example.com
```ini
[global]
repo1-host=repo1.example.com
repo1-host-user=pgbackrest
log-level-file=detail
compress-type=zst

[main]
pg1-path=/var/lib/pgsql/17/data
```

### 2.5 Init, backup, restore
```bash
# stanza-create + backup run FROM the repo host:
sudo -iu pgbackrest pgbackrest --stanza=main stanza-create
sudo -iu pgbackrest pgbackrest --stanza=main check
sudo -iu pgbackrest pgbackrest --stanza=main --type=full backup
# archive-push runs FROM the db host automatically via archive_command.
# check works from both sides:
sudo -iu postgres  pgbackrest --stanza=main check
# restore runs FROM the db host:
sudo systemctl stop postgresql-17
sudo -iu postgres pgbackrest --stanza=main --delta restore
```
Cron/timers for backups belong on the repo host (as pgbackrest).

### 2.6 Troubleshooting
- `ProtocolError` / version mismatch → align binary versions on both hosts (common after partial package upgrade).
- `Host key verification failed` → pre-populate `known_hosts` for both users.
- Backup-locality error → backups must be initiated from the repo host when repo1-host is set; restores from the db host.

---

## RECIPE 3 — Dedicated Repository Host via TLS Server

Modern alternative to SSH — the TLS server feature **shipped in release/2.37 on January 3, 2022** ("Add TLS server"). Each host runs a `pgbackrest server` TLS daemon on port 8432. Client CN is matched to stanzas via `tls-server-auth`. Note pgBackRest 2.58.0 requires TLS ≥ 1.2.

### 3.1 Private CA + certs
```bash
# CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=pgbackrest-CA"
# server/client cert per host (CN must match hostname used in tls-server-auth)
for host in repo1 pg1; do
  openssl genrsa -out $host.key 2048
  openssl req -new -key $host.key -out $host.csr -subj "/CN=$host.example.com"
  openssl x509 -req -in $host.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out $host.crt -days 825 -sha256
done
sudo mkdir -p /etc/pgbackrest/certs
sudo cp ca.crt *.crt *.key /etc/pgbackrest/certs/
sudo chown -R postgres:postgres /etc/pgbackrest/certs
sudo chmod 600 /etc/pgbackrest/certs/*.key
```

### 3.2 Config — repo1.example.com
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=4
repo1-bundle=y
repo1-block=y
compress-type=zst
start-fast=y
delta=y
process-max=4
# TLS server (accepts connections from pg1)
tls-server-address=*
tls-server-cert-file=/etc/pgbackrest/certs/repo1.example.com.crt
tls-server-key-file=/etc/pgbackrest/certs/repo1.example.com.key
tls-server-ca-file=/etc/pgbackrest/certs/ca.crt
tls-server-auth=pg1.example.com=main

[main]
pg1-host=pg1.example.com
pg1-host-type=tls
pg1-host-cert-file=/etc/pgbackrest/certs/repo1.example.com.crt
pg1-host-key-file=/etc/pgbackrest/certs/repo1.example.com.key
pg1-host-ca-file=/etc/pgbackrest/certs/ca.crt
pg1-path=/var/lib/pgsql/17/data
```

### 3.3 Config — pg1.example.com
```ini
[global]
repo1-host=repo1.example.com
repo1-host-type=tls
repo1-host-cert-file=/etc/pgbackrest/certs/pg1.example.com.crt
repo1-host-key-file=/etc/pgbackrest/certs/pg1.example.com.key
repo1-host-ca-file=/etc/pgbackrest/certs/ca.crt
compress-type=zst
# TLS server (accepts connections from repo1)
tls-server-address=*
tls-server-cert-file=/etc/pgbackrest/certs/pg1.example.com.crt
tls-server-key-file=/etc/pgbackrest/certs/pg1.example.com.key
tls-server-ca-file=/etc/pgbackrest/certs/ca.crt
tls-server-auth=repo1.example.com=main

[main]
pg1-path=/var/lib/pgsql/17/data
```

### 3.4 systemd unit for the TLS daemon (both hosts)
`/etc/systemd/system/pgbackrest.service`:
```ini
[Unit]
Description=pgBackRest Server
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=postgres
Restart=always
RestartSec=1
ExecStart=/usr/bin/pgbackrest server
ExecReload=/bin/kill -HUP $MAINPID
[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pgbackrest
pgbackrest server-ping    # aliveness check (no auth attempted)
ss -ltnp | grep 8432      # confirm listener
```

### 3.5 Init/backup/restore — same commands as SSH (from repo host)
```bash
sudo -iu postgres pgbackrest --stanza=main stanza-create
sudo -iu postgres pgbackrest --stanza=main check
sudo -iu postgres pgbackrest --stanza=main --type=full backup
```

### 3.6 Certificate rotation & revocation
- Rotate: issue new cert signed by same CA, replace files, `systemctl reload pgbackrest` (SIGHUP). Terminate/restart the daemon whenever `tls-*` config changes.
- **No CRL support**: to revoke a client, remove its `tls-server-auth=<CN>=<stanza>` line and restart the server daemon. The cert stays cryptographically valid but is denied access at the authorization layer.
- Firewall: open TCP 8432 only between DB and repo hosts.

### 3.7 Troubleshooting
- Connection refused → daemon not running / port 8432 blocked.
- Auth failure → CN in cert doesn't match `tls-server-auth` entry (wildcards allowed for stanza with `tls-server-auth=<CN>=*`, but NOT for the CN).
- `server-ping` succeeds but backup fails → cert/CA path or auth mapping wrong (server-ping does no authentication).

---

## RECIPE 4 — Direct to Object Storage (S3 / Azure / GCS)

Strongly recommend `repo-bundle=y` + `repo-block=y` on object stores to cut file counts and per-object costs, plus async archiving. (Note: 2.58.0 raised the minimum `repo-storage-upload-chunk-size` values to the vendor minimums.)

### 4.1 S3 primary recipe
```ini
[global]
repo1-type=s3
repo1-s3-bucket=acme-pgbackrest
repo1-s3-endpoint=s3.us-east-1.amazonaws.com
repo1-s3-region=us-east-1
repo1-path=/main
repo1-bundle=y
repo1-block=y
compress-type=zst
repo1-retention-full=4
start-fast=y
delta=y
process-max=4
# Async archiving essential for object stores:
archive-async=y
spool-path=/var/spool/pgbackrest

[global:archive-push]
process-max=4
[global:archive-get]
process-max=4

[main]
pg1-path=/var/lib/pgsql/17/data
```
Credential options (choose one):
```ini
# Static keys (store in a restricted include file, see 4.5):
repo1-s3-key=AKIA...
repo1-s3-key-secret=...
# OR IAM instance profile / EC2 role (auto-rotating temp creds):
repo1-s3-key-type=auto
repo1-s3-role=my-backup-role    # optional; auto-discovered if omitted
# OR EKS/web-identity:
repo1-s3-key-type=web-id        # needs AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE
```
`repo1-s3-key-type=auto` is strongly preferred on EC2/EKS — no long-lived secrets, credentials auto-refresh when ≤5 min from expiry (avoids the classic `ExpiredToken` failure mid-backup with hand-rolled token refresh).

URI style: default is host-style; use `repo1-s3-uri-style=path` for MinIO/older gateways.

S3-compatible (MinIO / Ceph RGW):
```ini
repo1-type=s3
repo1-s3-endpoint=minio.internal
repo1-s3-port=9000
repo1-s3-uri-style=path
repo1-s3-key=accessKey
repo1-s3-key-secret=secretKey
repo1-s3-region=us-east-1
repo1-storage-verify-tls=n     # only for self-signed test endpoints
```

Least-privilege IAM policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::acme-pgbackrest"},
    {"Effect": "Allow", "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject"],
     "Resource": "arn:aws:s3:::acme-pgbackrest/*"}
  ]
}
```
Storage class / ransomware protection: use S3 Versioning + Object Lock (WORM) on the bucket. Object Lock requires Versioning; compliance mode prevents deletion by anyone (even the AWS root account) for the retention period — protecting against credential compromise. Note pgBackRest `expire` needs delete rights, so reconcile Object Lock retention with your `repo1-retention-*`; a clean pattern is to keep the primary repo mutable and replicate to a separate immutable/locked repo or account (see Recipe 5) rather than locking the working repo.

### 4.2 Azure Blob
```ini
[global]
repo1-type=azure
repo1-azure-account=acmepgbackrest
repo1-azure-container=pgbackrest
repo1-azure-key-type=shared      # or 'sas'
repo1-azure-key=<storage-key-or-sas-token>
repo1-path=/main
repo1-bundle=y
repo1-block=y
```
Do NOT enable hierarchical namespace on the storage account (causes errors during expire). `repo1-azure-key-type=sas` uses a shared-access-signature token; managed identities are also supported.

### 4.3 GCS
```ini
[global]
repo1-type=gcs
repo1-gcs-bucket=acme-pgbackrest
repo1-gcs-key-type=service       # 'service' | 'auto' | 'token'
repo1-gcs-key=/etc/pgbackrest/gcs-key.json
repo1-path=/main
repo1-bundle=y
repo1-block=y
```
`repo1-gcs-key-type=auto` uses the instance service account (no key file). With `service`, `repo1-gcs-key` points to the service-account JSON key.

### 4.4 Encryption recipe
```bash
openssl rand -base64 48    # generate passphrase
```
```ini
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=<paste-generated-passphrase>
```
MUST be set BEFORE `stanza-create` — cannot be retrofitted to an existing repo (you would have to create a new repo/stanza). Encryption is always client-side even if the object store also encrypts at rest.

### 4.5 Secrets handling
Put secrets in a restricted include file, not the world-readable main config:
```bash
sudo install -o postgres -g postgres -m 600 /dev/null /etc/pgbackrest/conf.d/secret.conf
cat | sudo tee /etc/pgbackrest/conf.d/secret.conf >/dev/null <<'EOF'
[global]
repo1-cipher-pass=<passphrase>
repo1-s3-key=AKIA...
repo1-s3-key-secret=...
EOF
```
Alternatively use env vars (never on the command line): `PGBACKREST_REPO1_CIPHER_PASS`, `PGBACKREST_REPO1_S3_KEY_SECRET`.

### 4.6 Async archiving specifics
- `archive-async=y` + `spool-path` on fast LOCAL disk (Posix; NOT NFS/CIFS; NOT inside pg_wal — breaks pg_rewind).
- `archive-push`/`archive-get` `process-max` raises parallelism for high-latency object stores.
- `archive-push-queue-max` DANGER: when the queue exceeds this size in async mode, pgBackRest reports WAL as archived to PostgreSQL then DROPS the entire queue — PITR is broken past that point and a new backup is required. Its purpose is to stop pg_wal filling and crashing PostgreSQL ("better to lose the backup than have PostgreSQL go down"). Size it larger than your worst-case repo outage WAL volume; do NOT set it small if you rely on your backups.

### 4.7 Troubleshooting
- `ExpiredToken` mid-backup with manual IAM tokens → use `repo1-s3-key-type=auto`.
- `HTTP 400 (Bad Request)` on stanza-create → wrong endpoint/region/uri-style.
- Slow archiving → raise archive-push process-max; confirm async enabled.

---

## RECIPE 5 — Multi-Repo (local + cloud)

`repo1` = fast local/NFS posix (short retention, fast restores); `repo2` = S3 (long retention, DR).

```ini
[global]
# repo1: local, short retention
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-bundle=y
repo1-block=y
# repo2: S3, long retention, encrypted
repo2-type=s3
repo2-s3-bucket=acme-pgbackrest-dr
repo2-s3-endpoint=s3.us-east-1.amazonaws.com
repo2-s3-region=us-east-1
repo2-path=/main
repo2-s3-key-type=auto
repo2-bundle=y
repo2-block=y
repo2-cipher-type=aes-256-cbc
repo2-cipher-pass=<passphrase>
repo2-retention-full=12
compress-type=zst
start-fast=y
delta=y
archive-async=y
spool-path=/var/spool/pgbackrest

[main]
pg1-path=/var/lib/pgsql/17/data
```
Behavior:
- WAL `archive-push` writes to ALL configured repos automatically; if one repo is down, async archiving keeps the other alive.
- Backups are per-repo: schedule separately with `--repo`:
```bash
pgbackrest --stanza=main --repo=1 --type=diff backup   # daily local
pgbackrest --stanza=main --repo=2 --type=full backup   # weekly cloud
```
- `stanza-create`/`stanza-upgrade` act on all repos automatically; `stanza-delete` requires an explicit `--repo`.
- Restore selects repo1 first (highest priority); force with `--repo=2`.
- Cipher settings are per-repo (repo1 unencrypted local, repo2 encrypted cloud is a common split).
- Monitor both: `info` reports status per repo; `status: mixed` means one repo is unhealthy — inspect per-repo detail.

---

## RECIPE 6 — Patroni / HA Cluster Integration

### 6.1 Principles
- Identical `pgbackrest.conf` and same stanza name on ALL nodes. The stanza survives failover because the system-id is identical across primary and replicas.
- Only the primary archives WAL (replicas' archive_command effectively does nothing). After failover the new primary archives on a new timeline — WAL on the new timeline archives fine.
- Set `archive_mode` and `archive_command` via Patroni DCS so they are consistent; Patroni applies `archive_command` with reload semantics.

### 6.2 patroni.yml snippet
```yaml
bootstrap:
  dcs:
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        archive_mode: "on"
        archive_command: 'pgbackrest --stanza=main archive-push %p'
        max_wal_senders: 10
      recovery_conf:
        restore_command: 'pgbackrest --stanza=main archive-get %f "%p"'

postgresql:
  create_replica_methods:
    - pgbackrest
    - basebackup
  pgbackrest:
    command: '/usr/bin/pgbackrest --stanza=main --delta restore'
    keep_data: True
    no_params: True
  basebackup:
    max-rate: '100M'
```
`create_replica_methods` with pgbackrest lets new replicas be built from the backup repo (delta restore) instead of `pg_basebackup`, offloading the primary. Patroni tries methods in order, stopping at the first returning 0. `keep_data: True` + `no_params: True` are required so Patroni doesn't append its own `--datadir`/`--scope` args to the restore command.

### 6.3 Backup from standby
Configure BOTH primary and standby on the repo host (index pg1/pg2); enable `backup-standby`. Repo-host config:
```ini
[main]
pg1-host=pg1.example.com
pg1-host-user=postgres
pg1-path=/var/lib/pgsql/17/data
pg2-host=pg2.example.com
pg2-host-user=postgres
pg2-path=/var/lib/pgsql/17/data
[global]
backup-standby=prefer     # 'y' requires a standby (fails if down); 'prefer' falls back to primary
```
`backup-standby` values: `y` = standby required (backup fails if standby down); `prefer` = use standby if available else primary (added v2.54.0); `n` = primary only (default). Caveat: `prefer` only helps if NO standby is found — it will NOT rescue a backup if a responding standby then fails to sync with the primary after the backup starts. `backup-standby` requires both primary and standby to be configured.

### 6.4 Where to run scheduled backups in HA
- Best: on the dedicated repo host (single scheduler, no leader ambiguity).
- If cron/timer on all nodes, guard with a primary check so only the leader backs up (query `pg_is_in_recovery()` or Patroni REST `/primary`).

### 6.5 Timeline switches / PITR across failover
After failover PostgreSQL selects a new timeline ID. PITR across timelines requires `--target-timeline` (e.g. `--target-timeline=current` or a specific TLI). The classic trap: restoring a replica after an in-place primary restore fails because timelines diverged — you must rebuild the standby (wipe data dir, re-run pgbackrest create_replica).

### 6.6 Troubleshooting
- Replica won't build via pgbackrest → check `keep_data`/`no_params`; ensure empty data dir exists with mode 700.
- WAL archive failing on old primary after failover → expected; only the current primary archives.

---

## RECIPE 7 — Major Version Upgrade with stanza-upgrade

`stanza-upgrade` adds the new PG version/system-id to `archive.info` and `backup.info` history. Old backups remain restorable for the OLD version. A fresh full backup is required after upgrade because old backups belong to the old version.

### 7.1 Standalone workflow (PG16 → PG17)
```bash
# 1. Pre-upgrade: verified full backup + check
sudo -iu postgres pgbackrest --stanza=main --type=full backup
sudo -iu postgres pgbackrest --stanza=main check

# 2. Stop old cluster, run pg_upgrade (link or copy mode)
sudo systemctl stop postgresql-16
sudo -iu postgres /usr/pgsql-17/bin/pg_upgrade \
  --old-datadir=/var/lib/pgsql/16/data --new-datadir=/var/lib/pgsql/17/data \
  --old-bindir=/usr/pgsql-16/bin --new-bindir=/usr/pgsql-17/bin --link

# 3. Update pgbackrest.conf pg1-path to new data dir (all hosts / repo host)
#    [main] pg1-path=/var/lib/pgsql/17/data

# 4. Run stanza-upgrade BEFORE the new cluster starts archiving
#    (--no-online while the cluster is still down)
sudo -iu postgres pgbackrest --stanza=main --no-online stanza-upgrade

# 5. Update/confirm archive_command for the new version, start new cluster
sudo systemctl start postgresql-17

# 6. Verify + take immediate new full backup
sudo -iu postgres pgbackrest --stanza=main check
sudo -iu postgres pgbackrest --stanza=main --type=full backup
```
Ordering rule (from the official "Upgrading PostgreSQL" guide): the new `pg-path` must be set for all configs and `stanza-upgrade` run BEFORE starting the new cluster / before its first WAL archive attempt — otherwise archive-push fails with a version/system-id mismatch. On a dedicated repo host, run stanza-upgrade on the repo host.

- **link mode**: fast, but the old cluster becomes unusable once the new cluster starts — your pre-upgrade backup is your only rollback.
- **copy mode**: slower but the old cluster stays intact for rollback.
- Retention across upgrade: old-version backups still count/expire per retention; keep enough to satisfy your recovery window for the old version.

### 7.2 Patroni + pg_upgrade combined (brief)
1. Verified full backup (old cluster running).
2. `patronictl pause` (maintenance mode so Patroni won't restart/failover), then stop PostgreSQL on all nodes.
3. Run `pg_upgrade` on the PRIMARY only (running pg_upgrade on standbys is unsupported by PostgreSQL).
4. Update `pgN-path` in pgbackrest.conf on every node + repo host to the new data dir.
5. Run `pgbackrest stanza-upgrade` (`--no-online`) on the repo host — after pg_upgrade, before the new cluster starts archiving. This is what lets the new cluster's archive_command succeed.
6. Update patroni.yml paths/binaries, wipe old DCS state (`patronictl remove` / re-init, because pg_upgrade creates a new system identifier), start Patroni on the primary, rebuild replicas (wipe data dir → pgbackrest create_replica / delta restore), then `patronictl resume`.
7. `pgbackrest check` then a new full backup.

### 7.3 Troubleshooting
- archive-push mismatch after upgrade → stanza-upgrade not run or pg-path not updated.
- Rollback → restore the pre-upgrade backup (this is the mandatory path in link mode).

---

## RECIPE 8 — Operations Runbook (Day-2)

### 8.1 Monitoring
- `pgbackrest --stanza=main info --output=json` is the canonical machine-readable source.
- **check_pgbackrest** (Stefan Fercot; copyright Dalibo 2018–2020 / Stefan Fercot 2020–2024). Current version is **2.4, released July 5, 2024**, and it "is designed to monitor pgBackRest (2.52 and above) backups from Nagios." Services: `retention`, `archives`, `pgbackrest_version`. Output formats human/json/nagios/nagios_strict/prtg. Example:
```bash
check_pgbackrest --stanza=main --service=retention --retention-full=2 --output=human
check_pgbackrest --stanza=main --service=archives --repo-path=/main/archive
```
- **Prometheus**: woblerr/pgbackrest_exporter parses `info --output=json`; default listen `:9854` (`--web.listen-address`), default bundled pgBackRest version v2.56.0. Useful metrics: `pgbackrest_backup_last_*`, `pgbackrest_stanza_status` (0=ok,2=no valid backups, etc.), and (v2.56+) `pgbackrest_stanza_restore_lock_status`. Crunchy pgMonitor exposes `ccp_backrest_last_full_backup_time_since_completion_seconds` and friends.
- WAL archive lag: query `pg_stat_archiver` (`last_archived_time`, `failed_count`, `last_failed_wal`).
- Alert thresholds (tune to RPO): last successful backup age > 26h (daily schedule), WAL not archived > 5–10 min, `failed_count` increasing, stanza status != ok, TLS cert < 30 days to expiry.

### 8.2 Scheduled verification & test restores
```bash
pgbackrest --stanza=main verify                # checksum-validate repo contents
```
Run quarterly full restore drills to an isolated host (TLS mode is ideal for isolated DR restores — no SSH relationship to production). Watch for page-checksum WARN lines in backup output — they indicate early data-page corruption (backup does not abort; invalid pages are recorded in the manifest), letting you catch corruption before good backups expire.

### 8.3 Expire / retention management
```bash
pgbackrest --stanza=main expire                          # apply retention now
pgbackrest --stanza=main --set=20260714-020000F expire   # ad-hoc expire a specific set
```
Change retention by editing `repo1-retention-*` then running expire. Re-visit the WAL retention trap: do not shrink `repo1-retention-archive` unless you accept losing PITR for older backups.

### 8.4 Resume, stop/start, locks
- Failed backups auto-resume by default (`resume=y`); already-copied files are matched by checksum in the manifest.
- Pause all pgBackRest activity for a stanza: `pgbackrest --stanza=main stop` / `pgbackrest --stanza=main start`. `stop --force` terminates running processes.
- Lock files live in `/tmp/pgbackrest` by default (`lock-path`). Clear stale locks only after confirming no pgBackRest process is running.

### 8.5 Log management
```ini
[global]
log-level-file=detail
log-path=/var/log/pgbackrest
```
logrotate `/etc/logrotate.d/pgbackrest`:
```
/var/log/pgbackrest/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 postgres postgres
}
```

### 8.6 Performance tuning quick reference
| Option | Guidance |
|---|---|
| process-max (backup) | ~ half of CPU cores (online, competes with PG) |
| process-max (restore) | most cores (PG stopped) |
| process-max (archive-push/get) | 2–4; raise for high-latency object stores |
| compress-type | zst (fast, good ratio; since v2.27) |
| compress-level | 6 backup; 3 for archive-push (speed) |
| buffer-size | raise (e.g. 4–16MiB) for large sequential I/O |
| io-timeout | 60s default; raise for slow/high-latency storage |
| db-timeout | must be < protocol-timeout |
| protocol-timeout | must be > db-timeout (default 1830s) |
| manifest-save-threshold | default 1GiB; raise (e.g. 8GiB) for very large DBs to reduce manifest saves |

### 8.7 Common failure modes
| Symptom | Fix |
|---|---|
| archive-push failing, pg_wal filling | check repo connectivity/perms; async keeps other repos alive; do NOT let archive-push-queue-max silently drop WAL |
| stanza mismatch after restoring different cluster | fresh repo/stanza; never mix system-ids |
| checksum errors in info files | investigate storage; run verify; restore from another repo if needed |
| interrupted backup | resumes automatically next run |
| version mismatch between hosts | align exact pgBackRest versions (partial package upgrade is the usual cause) |
| expired WAL needed by standby | retention too aggressive; rebuild standby / widen retention |

### 8.8 Security checklist
- Config file perms 640, owned postgres:postgres (or root:postgres); keys/passphrase in restricted include file (`conf.d/secret.conf`, mode 600) or env var.
- Cipher passphrase never in world-readable config; generate with `openssl rand -base64 48`.
- Dedicated `pgbackrest` repo user (not postgres) on the repo host; SSH key command-restriction, or TLS with per-CN authorization.
- Monitor TLS cert expiry; rotate before expiry (825-day cert lifetime in the example above).
- Least-privilege IAM for object storage; prefer `repo1-s3-key-type=auto` over static keys; consider Versioning + Object Lock (compliance mode) for ransomware resilience, kept on a separate/replicated repo so `expire` on the working repo is unaffected.

---

## Recommendations (staged rollout)

**Stage 1 — Establish a safe baseline (day 1):** Deploy Recipe 0 + Recipe 1 (local repo) on the existing cluster. Enable `archive_mode=on` at your next maintenance window (placeholder command first), reload the real `archive_command`, run stanza-create/check/full backup. Threshold to advance: a green `check` and one successful full backup verified with `info`.

**Stage 2 — Make it disaster-safe (week 1):** Add an off-host or cloud repo. For most shops, jump straight to Recipe 4 (S3 with `repo-bundle=y`, `repo-block=y`, encryption, async archiving) or Recipe 5 (local repo1 for fast restores + cloud repo2 for DR). Prefer `repo1-s3-key-type=auto` on EC2/EKS. Threshold: successful backup to the remote repo and a **test restore to a scratch path** (`--pg1-path`).

**Stage 3 — Harden the transport (week 2–3):** If you run a dedicated repo host, choose TLS (Recipe 3) over SSH (Recipe 2) for new builds — cleaner key management, per-CN authorization, and better performance. Keep SSH only where TLS certificate management is impractical. Threshold: `server-ping` + `check` from both directions.

**Stage 4 — Integrate with HA (week 3–4):** For Patroni clusters, standardize the stanza across nodes, wire `create_replica_methods: [pgbackrest, basebackup]`, and use `backup-standby=prefer` to offload the primary while tolerating standby outages. Run scheduled backups from the repo host. Threshold: a replica successfully rebuilt via pgbackrest delta restore.

**Stage 5 — Operationalize (ongoing):** Deploy monitoring (check_pgbackrest and/or the Prometheus exporter), set alert thresholds (backup age, WAL lag, stanza status, cert expiry), schedule `verify`, and put a **quarterly restore drill** on the calendar. Rehearse the Recipe 7 upgrade workflow in staging before any production major-version upgrade.

**What would change these recommendations:** databases > ~1 TB → raise `process-max`, `buffer-size`, `manifest-save-threshold`, and strongly favor `repo-block=y`; very high WAL generation → tune async `process-max` and size `archive-push-queue-max` generously; strict compliance/immutability needs → add Object Lock on a replicated repo; ephemeral/isolated DR environments → prefer TLS transport.

---

## Caveats
- **Version currency:** All option names, defaults, and behaviors are for pgBackRest 2.58.0 (released Jan 19, 2026) and PostgreSQL 17/18-era settings. `repo-block` needs v2.52.1+ readers; `backup-standby=prefer` needs v2.54.0+; the TLS server needs v2.37+. Enabling `repo-bundle`/`repo-block` makes the repo unreadable by older pgBackRest.
- **Exact-version matching** across all participating hosts is mandatory; partial package upgrades are the most common cause of ProtocolError in remote setups.
- **The WAL retention trap and archive-push-queue-max** are the two settings most likely to silently destroy recoverability — treat both conservatively. `archive-push-queue-max` intentionally sacrifices backup completeness to keep PostgreSQL alive when the repo is unreachable.
- **Encryption cannot be retrofitted** — decide before stanza-create.
- **Patroni-specific steps** (pause/resume, DCS wipe, replica rebuild) come from Patroni docs and practitioner guides (Percona, pgstef, dbi-services), not the pgBackRest manual itself; exact commands vary by deployment. Validate the full upgrade sequence in staging.
- **Object Lock vs. expire:** immutable buckets can block pgBackRest's own `expire`; design retention and immutability windows together, ideally isolating immutability to a secondary repo/account.
- Several cited community examples (Percona, EDB, pgstef) use older PostgreSQL/pgBackRest versions in their walkthroughs; the commands here have been updated to 2.58.0 syntax and PG 17 paths, but always dry-run in a lab first.