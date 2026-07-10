#!/bin/bash
# Lab 3 - Automated Verification Test Script
set -e

echo "=== Starting Lab 3 (Backup from Standby) Verification ==="

# Clean up any existing containers/volumes
docker compose down -v --remove-orphans

# Start the environment
echo "--> Starting containers..."
docker compose up -d

# Wait for primary and standby to start
echo "--> Waiting for PostgreSQL primary to become ready..."
until docker exec -u postgres pg-primary-replic pg_isready -h localhost -U postgres; do
    sleep 1
done
echo "PostgreSQL primary is ready."

echo "--> Waiting for PostgreSQL standby to become ready..."
until docker exec -u postgres pg-standby-replic pg_isready -h localhost -U postgres; do
    sleep 1
done
echo "PostgreSQL standby is ready."

# Verify replication status
echo "--> Checking replication status on primary..."
docker exec -u postgres pg-primary-replic psql -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"

# Create the stanza on the repository host
echo "--> Creating pgBackRest stanza..."
docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo stanza-create

# Check the stanza configuration
echo "--> Verifying stanza configuration..."
docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo check

# Create a test table and insert data on primary
echo "--> Writing test data to primary..."
docker exec -u postgres pg-primary-replic psql -c "
    CREATE TABLE test_table (
        id serial PRIMARY KEY,
        val text,
        created_at timestamp DEFAULT now()
    );
    INSERT INTO test_table (val) VALUES ('Initial replica test data');
"

# Force WAL switch and wait for replication to catch up
docker exec -u postgres pg-primary-replic psql -c "SELECT pg_switch_wal();"
sleep 2

# Verify data exists on the standby
echo "--> Verifying data streamed to standby..."
STANDBY_VAL=$(docker exec -u postgres pg-standby-replic psql -t -A -c "SELECT val FROM test_table;")
if [ "$STANDBY_VAL" = "Initial replica test data" ]; then
    echo "Replication verification: Success"
else
    echo "❌ Error: Standby did not receive the replicated data!"
    exit 1
fi

# Run a Full Backup (pgBackRest should backup from pg-standby-replic, not pg-primary-replic)
echo "--> Running Full Backup from Standby..."
docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo --type=full backup

# Simulate Standby Crash (completely wipe it)
echo "--> Simulating standby server crash (stopping and wiping database files)..."
docker exec -u postgres pg-standby-replic /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m immediate stop
docker exec -u postgres pg-standby-replic bash -c "rm -rf /var/lib/postgresql/16/main/*"

# Bootstrap Standby from pgBackRest
echo "--> Bootstrapping standby database using pgBackRest..."
docker exec -u postgres pg-standby-replic pgbackrest --stanza=demo --type=standby restore

# Add primary connection info to the restored standby configuration
echo "--> Reconfiguring streaming connection parameters on restored standby..."
docker exec -u postgres pg-standby-replic bash -c "
    echo \"primary_conninfo = 'host=pg-primary-replic port=5432 user=replication_user password=replica_password'\" >> /var/lib/postgresql/16/main/postgresql.auto.conf
"

# Restart the standby database
echo "--> Restarting standby database..."
docker exec -u postgres pg-standby-replic /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

# Wait for standby to be ready
until docker exec -u postgres pg-standby-replic pg_isready -h localhost -U postgres; do
    sleep 1
done

# Insert new data on primary to verify replication has resumed
echo "--> Writing new data on primary to test replication post-restore..."
docker exec -u postgres pg-primary-replic psql -c "INSERT INTO test_table (val) VALUES ('Data after replica bootstrap');"
docker exec -u postgres pg-primary-replic psql -c "SELECT pg_switch_wal();"
sleep 2

# Verify both records exist on the standby
echo "--> Verifying all data on standby..."
RESULT=$(docker exec -u postgres pg-standby-replic psql -t -A -c "SELECT val FROM test_table ORDER BY id;")
EXPECTED=$'Initial replica test data\nData after replica bootstrap'

if [ "$RESULT" = "$EXPECTED" ]; then
    echo "✅ Success: Standby was successfully bootstrapped from backup, and streaming replication resumed!"
else
    echo "❌ Error: Data verification on standby failed!"
    echo "Got:"
    echo "$RESULT"
    echo "Expected:"
    echo "$EXPECTED"
    exit 1
fi

# Clean up
docker compose down -v
echo "=== Lab 3 Verification Completed Successfully! ==="
