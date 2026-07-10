#!/bin/bash
# Lab 4 - Automated Verification Test Script
set -e

echo "=== Starting Lab 4 (Troubleshooting Scenarios) Verification ==="

# Clean up any existing containers/volumes
docker compose down -v --remove-orphans

# Start the environment
echo "--> Starting containers..."
docker compose up -d

# Wait for primary to be ready
echo "--> Waiting for PostgreSQL primary to become ready..."
until docker exec -u postgres pg-primary-debug pg_isready -h localhost -U postgres; do
    sleep 1
done
echo "PostgreSQL primary is ready."

# Initialize Stanza
echo "--> Initializing stanza..."
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo stanza-create
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check

# ==========================================
# Scenario 1: System Identifier Mismatch
# ==========================================
echo "--------------------------------------------"
echo "Testing Scenario 1: System Identifier Mismatch"
echo "--------------------------------------------"
chmod +x scenarios/break-stanza-mismatch.sh
./scenarios/break-stanza-mismatch.sh

# Verify that check command fails
echo "Verifying check command fails (expecting error)..."
if docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check 2>&1 | grep -q -E "database system-id|do not match the database"; then
    echo "Check failed as expected."
else
    echo "❌ Error: Check command did not fail with system-id mismatch!"
    exit 1
fi

# Apply Fix: Upgrade stanza to update system identifier
echo "Applying Fix: Upgrading stanza..."
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo stanza-upgrade

# Verify that check command now succeeds
echo "Verifying check command succeeds..."
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check
echo "✅ Scenario 1 resolved successfully!"

# ==========================================
# Scenario 2: Locked Repository
# ==========================================
echo "--------------------------------------------"
echo "Testing Scenario 2: Locked Repository"
echo "--------------------------------------------"
chmod +x scenarios/break-repo-locked.sh
./scenarios/break-repo-locked.sh

# Verify that backup command fails due to lock
echo "Verifying backup command fails (expecting lock error)..."
if docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo --type=full backup 2>&1 | grep -q "lock"; then
    echo "Backup failed as expected due to lock file."
else
    echo "❌ Error: Backup command did not fail with lock error!"
    exit 1
fi

# Apply Fix: Clear the lock file
echo "Applying Fix: Clearing lock file..."
docker exec -u postgres pgbackrest-repo-debug rm -f /tmp/pgbackrest/demo-backup-1.lock

# Verify that backup command now succeeds
echo "Verifying backup command succeeds..."
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo --type=full backup
echo "✅ Scenario 2 resolved successfully!"

# ==========================================
# Scenario 3: SSH Connection Denied
# ==========================================
echo "--------------------------------------------"
echo "Testing Scenario 3: SSH Connection Denied"
echo "--------------------------------------------"
chmod +x scenarios/break-ssh-denied.sh
./scenarios/break-ssh-denied.sh

# Verify that check command fails due to SSH
echo "Verifying check command fails (expecting SSH error)..."
if docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check 2>&1 | grep -q "ssh"; then
    echo "Check failed as expected due to SSH error."
else
    # Also accept standard connection error if grep for 'ssh' is not exact
    echo "Check command failed. Verifying connection error..."
    if ! docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check >/dev/null 2>&1; then
        echo "Check failed as expected."
    else
        echo "❌ Error: Check command did not fail with SSH connection error!"
        exit 1
    fi
fi

# Apply Fix: Restore authorized_keys file
echo "Applying Fix: Restoring authorized_keys..."
docker exec -u postgres pg-primary-debug mv /var/lib/postgresql/.ssh/authorized_keys.bak /var/lib/postgresql/.ssh/authorized_keys

# Verify that check command now succeeds
echo "Verifying check command succeeds..."
docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check
echo "✅ Scenario 3 resolved successfully!"

# Clean up
docker compose down -v
echo "=== Lab 4 Verification Completed Successfully! ==="
