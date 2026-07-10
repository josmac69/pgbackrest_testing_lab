#!/bin/bash
# Break script for Scenario 1: System Identifier Mismatch
set -e

echo "--> Triggering Scenario 1: System Identifier Mismatch..."

# Make sure containers are running and stanza is initialized first
docker exec -u postgres pg-primary-debug pg_isready -h localhost -U postgres >/dev/null || {
    echo "Error: Database is not running. Start the lab first using 'make up' and run 'make setup'."
    exit 1
}

# Stop PostgreSQL
echo "Stopping PostgreSQL..."
docker exec -u postgres pg-primary-debug /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m immediate stop

# Wipe data directory and run a fresh initdb (this changes the system identifier)
echo "Re-initializing database to change system identifier..."
docker exec -u postgres pg-primary-debug bash -c "
    rm -rf /var/lib/postgresql/16/main/*
    /usr/lib/postgresql/16/bin/initdb -D /var/lib/postgresql/16/main -U postgres --auth-local=peer
"

# Re-append pgBackRest settings
docker exec -u postgres pg-primary-debug bash -c "
    cat <<EOF >> /var/lib/postgresql/16/main/postgresql.conf
# pgBackRest configurations
archive_mode = on
archive_command = 'pgbackrest --stanza=demo archive-push %p'
max_wal_senders = 10
wal_level = replica
hot_standby = on
listen_addresses = '*'
EOF
"

# Restart the database
echo "Starting PostgreSQL..."
docker exec -u postgres pg-primary-debug /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

echo "--> Scenario 1 triggered! Try running 'make check' or 'make backup' to see the failure."
echo "--> Diagnosing error: inspect pgbackrest logs on pgbackrest-repo-debug."
