#!/bin/bash
# Break script for Scenario 2: Locked Repository
set -e

echo "--> Triggering Scenario 2: Locked Repository..."

# Ensure containers are running
docker exec -u postgres pgbackrest-repo-debug ls /var/lib/pgbackrest >/dev/null || {
    echo "Error: Repository container is not running. Run 'make up' first."
    exit 1
}

# Create lock directory and mock lock file
echo "Injecting stale lock file in repository..."
docker exec -u postgres pgbackrest-repo-debug bash -c "
    mkdir -p /tmp/pgbackrest
    touch /tmp/pgbackrest/demo-backup-1.lock
"
docker exec -d -u postgres pgbackrest-repo-debug flock -x /tmp/pgbackrest/demo-backup-1.lock sleep 300

echo "--> Scenario 2 triggered! Try running 'make backup' to observe the lock failure."
echo "--> Diagnosing error: check pgBackRest output and look for lock file warnings."
