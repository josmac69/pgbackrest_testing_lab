#!/bin/bash
# Lab 1 - Automated Verification Test Script
set -e

echo "=== Starting Lab 1 (Basic SSH Repo) Verification ==="

# Clean up any existing containers/volumes
docker compose down -v --remove-orphans

# Start the environment
echo "--> Starting containers..."
docker compose up -d

# Wait for primary to be ready
echo "--> Waiting for PostgreSQL primary to become ready..."
until docker exec -u postgres pg-primary pg_isready -h localhost -U postgres; do
    sleep 1
done
echo "PostgreSQL primary is ready."

# Verify SSH connectivity
echo "--> Verifying SSH connectivity..."
docker exec -u postgres pg-primary ssh pgbackrest-repo echo "SSH from primary to repo is working!"
docker exec -u postgres pgbackrest-repo ssh pg-primary echo "SSH from repo to primary is working!"

# Create the stanza on the repository host
echo "--> Creating pgBackRest stanza..."
docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo stanza-create

# Check the stanza configuration
echo "--> Verifying stanza configuration..."
docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo check

# Create a test table and insert initial data
echo "--> Creating test database schema and inserting initial data..."
docker exec -u postgres pg-primary psql -c "
    CREATE TABLE test_table (
        id serial PRIMARY KEY,
        val text,
        created_at timestamp DEFAULT now()
    );
    INSERT INTO test_table (val) VALUES ('Initial data');
"

# Force WAL switch to trigger archiving
docker exec -u postgres pg-primary psql -c "SELECT pg_switch_wal();"

# Perform a Full Backup
echo "--> Running a Full Backup..."
docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo --type=full backup

# Insert incremental data
echo "--> Inserting incremental data..."
docker exec -u postgres pg-primary psql -c "INSERT INTO test_table (val) VALUES ('Incremental data');"

# Force WAL switch
docker exec -u postgres pg-primary psql -c "SELECT pg_switch_wal();"

# Perform an Incremental Backup
echo "--> Running an Incremental Backup..."
docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo --type=incr backup

# Verify backup info
echo "--> Inspecting backup information..."
docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo info

# Simulate data corruption (total loss of PGDATA)
echo "--> Simulating database corruption (deleting all database files)..."
docker exec -u postgres pg-primary /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m immediate stop
docker exec -u postgres pg-primary bash -c "rm -rf /var/lib/postgresql/16/main/*"

# Perform Restore (must be run on the database host, not the repo host)
echo "--> Performing pgBackRest restore..."
docker exec -u postgres pg-primary pgbackrest --stanza=demo restore

# Restart the restored database
echo "--> Restarting the restored database..."
docker exec -u postgres pg-primary /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

# Wait for PG to start
until docker exec -u postgres pg-primary pg_isready -h localhost -U postgres; do
    sleep 1
done

# Verify data was restored correctly
echo "--> Verifying data integrity..."
RESULT=$(docker exec -u postgres pg-primary psql -t -A -c "SELECT val FROM test_table ORDER BY id;")
EXPECTED=$'Initial data\nIncremental data'

if [ "$RESULT" = "$EXPECTED" ]; then
    echo "✅ Success: All data was successfully restored!"
else
    echo "❌ Error: Data verification failed!"
    echo "Got:"
    echo "$RESULT"
    echo "Expected:"
    echo "$EXPECTED"
    exit 1
fi

# Clean up
docker compose down -v
echo "=== Lab 1 Verification Completed Successfully! ==="
