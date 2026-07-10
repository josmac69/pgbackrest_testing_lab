#!/bin/bash
# Lab 2 - Automated Verification Test Script
set -e

echo "=== Starting Lab 2 (S3 MinIO & PITR) Verification ==="

# Clean up any existing containers/volumes
docker compose down -v --remove-orphans

# Generate self-signed TLS certs for MinIO if they don't exist
if [ ! -f certs/private.key ]; then
    echo "--> Generating self-signed TLS certificates for MinIO..."
    mkdir -p certs
    openssl req -new -x509 -nodes -days 365 \
      -keyout certs/private.key \
      -out certs/public.crt \
      -subj "/CN=minio" \
      -addext "subjectAltName=DNS:minio,DNS:localhost,IP:127.0.0.1"
    chmod 644 certs/private.key certs/public.crt
fi

# Start the environment
echo "--> Starting containers..."
docker compose up -d

# Wait for primary to be ready
echo "--> Waiting for PostgreSQL primary to become ready..."
until docker exec -u postgres pg-primary-s3 pg_isready -h localhost -U postgres; do
    sleep 1
done
echo "PostgreSQL primary is ready."

# Create the stanza
echo "--> Creating pgBackRest stanza on S3..."
docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo stanza-create

# Check the stanza configuration
echo "--> Verifying stanza configuration..."
docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo check

# Create a test table and insert initial data (T1)
echo "--> Inserting initial data (T1)..."
docker exec -u postgres pg-primary-s3 psql -c "
    CREATE TABLE test_table (
        id serial PRIMARY KEY,
        val text,
        created_at timestamp DEFAULT now()
    );
    INSERT INTO test_table (val) VALUES ('Initial data T1');
"

# Force WAL switch
docker exec -u postgres pg-primary-s3 psql -c "SELECT pg_switch_wal();"

# Perform a Full Backup
echo "--> Running a Full Backup..."
docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo --type=full backup

# Sleep for a moment to ensure clear separation of timestamps
sleep 2

# Insert good data (T2)
echo "--> Inserting good data (T2)..."
docker exec -u postgres pg-primary-s3 psql -c "INSERT INTO test_table (val) VALUES ('Good data T2');"
docker exec -u postgres pg-primary-s3 psql -c "SELECT pg_switch_wal();"

# Sleep to ensure separation
sleep 2

# Grab the current timestamp from database to use as recovery target (T2 timestamp)
echo "--> Retrieving recovery target timestamp..."
TARGET_TIME=$(docker exec -u postgres pg-primary-s3 psql -t -A -c "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS.US') || '+00';")
echo "Recovery Target Time set to: $TARGET_TIME"

# Sleep to ensure separation
sleep 2

# Simulate user error: drop the table (T3)
echo "--> Simulating accidental DROP TABLE (T3)..."
docker exec -u postgres pg-primary-s3 psql -c "DROP TABLE test_table;"

# Force WAL switch to ensure the drop event and trailing WAL are archived
docker exec -u postgres pg-primary-s3 psql -c "SELECT pg_switch_wal();"
sleep 2

# Stop PostgreSQL
echo "--> Stopping database..."
docker exec -u postgres pg-primary-s3 /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m fast stop

# Wipe the data directory for restore
docker exec -u postgres pg-primary-s3 bash -c "rm -rf /var/lib/postgresql/16/main/*"

# Perform PITR Restore
echo "--> Restoring database to target timestamp: $TARGET_TIME"
docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo --type=time --target="$TARGET_TIME" --target-action=promote restore

# Start PostgreSQL (it will automatically enter recovery mode and replay WALs to the target time)
echo "--> Starting database in recovery mode..."
docker exec -u postgres pg-primary-s3 /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

# Wait for PG to start
echo "--> Waiting for PostgreSQL recovery to complete..."
until docker exec -u postgres pg-primary-s3 pg_isready -h localhost -U postgres; do
    sleep 1
done

# Verify data was restored up to T2 and the table exists
echo "--> Verifying data integrity..."
RESULT=$(docker exec -u postgres pg-primary-s3 psql -t -A -c "SELECT val FROM test_table ORDER BY id;")
EXPECTED=$'Initial data T1\nGood data T2'

if [ "$RESULT" = "$EXPECTED" ]; then
    echo "✅ Success: Point-in-Time Recovery succeeded! Table restored to state before deletion."
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
rm -rf certs
echo "=== Lab 2 Verification Completed Successfully! ==="
