#!/bin/bash
# Break script for Scenario 3: SSH Connection Denied
set -e

echo "--> Triggering Scenario 3: SSH Connection Denied..."

# Ensure containers are running
docker exec -u postgres pg-primary-debug pg_isready -h localhost -U postgres >/dev/null || {
    echo "Error: Database container is not running. Run 'make up' first."
    exit 1
}

# Break SSH access by renaming authorized_keys on the primary database host
echo "Renaming authorized_keys on pg-primary-debug..."
docker exec -u postgres pg-primary-debug bash -c "
    if [ -f /var/lib/postgresql/.ssh/authorized_keys ]; then
        mv /var/lib/postgresql/.ssh/authorized_keys /var/lib/postgresql/.ssh/authorized_keys.bak
    else
        echo 'authorized_keys already renamed or missing!'
    fi
"

echo "--> Scenario 3 triggered! Try running 'make check' or 'make backup' from the repo host."
echo "--> Diagnosing error: inspect why the repository cannot connect to the database node."
