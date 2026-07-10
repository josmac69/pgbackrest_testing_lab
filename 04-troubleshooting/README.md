# Lab 4: Troubleshooting & Failures Lab ("Fix-It")

## 🎯 Objectives
- Build practical, real-world troubleshooting skills for pgBackRest.
- Learn how to read and interpret typical pgBackRest error messages.
- Resolve three common production failures:
  1. System Identifier Mismatch.
  2. Locked Repository (Stale Locks).
  3. SSH Connection Failures.

---

## 🏗️ Architecture

This lab uses a standard two-node database and repository setup:
- `pg-primary-debug` (Database Host)
- `pgbackrest-repo-debug` (Repository Host)

You will use pre-configured scripts to intentionally "break" the setup. Your task is to diagnose the error using logs and command output, and then resolve the issue.

```mermaid
graph TD
    repo[pgbackrest-repo-debug]
    db[pg-primary-debug]

    repo -- "make check / make backup" --> db
    Note over repo,db: Students trigger scenarios which break<br>SSH, change DB identity, or lock files.
```

---

## ⚙️ Baseline Setup
Before trying the scenarios, build and initialize the healthy baseline:
```bash
make up
make stanza-create
make check
make backup
```

---

## 🔍 Scenario 1: System Identifier Mismatch

### 1. Trigger the Failure
Run the trigger script:
```bash
make break-scenario1
```

### 2. Observe the Symptom
Attempt to run a check command from the repository:
```bash
make check
```
Observe the error message. You will see something like:
```
ERROR: [027]: database system-id [739485720495837] does not match stanza system-id [628394857201948]
```

### 3. Diagnosis & Concept
PostgreSQL assigns a unique **System Identifier** to every cluster during initialization (`initdb`). This ID ensures that archives and backups are never mixed up or restored to a different database by accident.
In this scenario, the database data directory was wiped and re-initialized, generating a new System ID. The pgBackRest stanza metadata inside the repository still expects the original System ID.

### 4. Resolution
To fix this, you must tell pgBackRest to update the stanza's system identifier. In modern pgBackRest versions, the `--force` flag for `stanza-create` is deprecated and no longer supported. Instead, you must use the `stanza-upgrade` command to update the stanza metadata to match the new database system identifier.

Run the stanza upgrade command from the repository:
```bash
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo stanza-upgrade
```
Now, verify the system is healthy again:
```bash
make check
```

---

## 🔒 Scenario 2: Locked Repository (Stale Locks)

### 1. Trigger the Failure
Run the trigger script:
```bash
make break-scenario2
```

### 2. Observe the Symptom
Attempt to run a backup:
```bash
make backup
```
Observe the error message. You will see:
```
ERROR: [049]: backup command already running
```

### 3. Diagnosis & Concept
To prevent concurrent backups from corrupting the repository, pgBackRest creates a lock file (e.g. `demo-backup-1.lock`) when a backup begins. If a backup process is forcefully killed (or the server crashes), this lock file may remain behind, blocking all future backups.

### 4. Resolution
Check if a backup process is actually running on the repository container:
```bash
docker exec -u postgres pgbackrest-repo-debug ps aux | grep pgbackrest
```
If no backup process is running, you can safely remove the stale lock file. The default lock path is `/tmp/pgbackrest/`.
Delete the lock file:
```bash
docker exec -u postgres pgbackrest-repo-debug rm -f /tmp/pgbackrest/demo-backup-1.lock
```
Try running the backup again:
```bash
make backup
```
It should complete successfully.

---

## 🔑 Scenario 3: SSH Connection Denied

### 1. Trigger the Failure
Run the trigger script:
```bash
make break-scenario3
```

### 2. Observe the Symptom
Attempt to run a check command:
```bash
make check
```
Observe the error message:
```
ERROR: [050]: ... Host key verification failed / Permission denied (publickey)
```

### 3. Diagnosis & Concept
Because pgBackRest routes all database controls and file copies through SSH in this architecture, passwordless SSH must be fully functional. Typical reasons for SSH failure in production are:
- The SSH service is stopped on the database host.
- The `postgres` user's SSH keys were modified or deleted.
- Permissions on `.ssh` (should be `700`) or `authorized_keys` (should be `600`) are too open (SSH server rejects them for security reasons).

### 4. Resolution
Check SSH connectivity manually from the repository to the primary:
```bash
docker exec -u postgres pgbackrest-repo-debug ssh pg-primary-debug
```
You will see that the connection is refused or denied.
In this case, the `authorized_keys` file was renamed to `authorized_keys.bak`. 

Restore the file on the database host:
```bash
docker exec -u postgres pg-primary-debug mv /var/lib/postgresql/.ssh/authorized_keys.bak /var/lib/postgresql/.ssh/authorized_keys
```
Verify the fix:
```bash
make check
```

---

## 🧹 Cleanup
Stop the lab and clean the volumes:
```bash
make down
```

---

## 💡 Key Troubleshooting Commands
- **Check Stanza Status**: `pgbackrest --stanza=demo info`
- **pgBackRest Log Location**: `/var/log/pgbackrest/` (contains files named after the stanza, e.g. `demo-backup.log` and `demo-archive-push.log`).
- **PostgreSQL Logs**: Look inside `/var/lib/postgresql/postgresql.log` to see why the `archive_command` is failing.
