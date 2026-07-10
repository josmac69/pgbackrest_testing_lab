# Lab 2: S3-Compatible Storage & Point-in-Time Recovery (PITR)

## 🎯 Objectives
- Configure pgBackRest to archive WALs and store backups directly in an S3-compatible object store (MinIO).
- Understand how pgBackRest communicates with object storage without SSH.
- Capture specific database timestamps for recovery.
- Simulate an accidental `DROP TABLE` disaster.
- Perform Point-in-Time Recovery (PITR) to restore the database to the exact millisecond before the disaster.

---

## 🏗️ Architecture

In modern cloud environments, backup repositories are typically hosted on object storage (like AWS S3, Google Cloud Storage, or Azure Blob Storage). In this lab, we use **MinIO**, an open-source, S3-compatible object store running locally.

Unlike Lab 1, where communication occurs over SSH via the pgBackRest daemon, here `pg-primary` talks directly to the S3 API endpoint over HTTP (port 9000).

```mermaid
graph LR
    subgraph Lab Network
        pg-primary[PostgreSQL Database<br>pg-primary-s3]
        minio[MinIO Object Store<br>minio:9000]
    end

    pg-primary -- "S3 API (HTTP)" --> minio
    Note over pg-primary: pgbackrest uploads WALs & backups<br>directly to bucket 'pgbackrest'
```

---

## ⚙️ Configuration Files

### Database Host Config (`pg-primary.conf` ➡️ `/etc/pgbackrest/pgbackrest.conf`)
The database host acts as its own backup client, speaking directly to S3:
```ini
[global]
repo1-type=s3                      # Tells pgBackRest to use S3 storage driver
repo1-path=/demo-s3                # Directory prefix inside the bucket
repo1-s3-bucket=pgbackrest         # Target S3 bucket name
repo1-s3-endpoint=minio            # Endpoint of our MinIO container
repo1-storage-port=9000            # Connect to port 9000
repo1-storage-verify-tls=n         # Use plain HTTP (no SSL/TLS)
repo1-s3-key=minioadmin            # Access Key ID
repo1-s3-key-secret=minioadmin      # Secret Access Key
repo1-s3-region=us-east-1          # Mandatory field (MinIO ignores it, but pgBackRest requires it)
repo1-s3-uri-style=path            # Crucial for local MinIO (uses endpoint/bucket instead of bucket.endpoint)
log-level-console=info
log-level-file=debug
start-fast=y

[demo]
pg1-path=/var/lib/postgresql/16/main
```

---

## 🧑‍💻 Hands-On Lab Exercises

### Step 1: Start the Environment
Initialize the Lab 2 containers:
```bash
make up
```
This launches MinIO, executes a helper container to create the `pgbackrest` bucket automatically, and starts `pg-primary`.

### Step 2: Create the Stanza
Because pgBackRest talks directly to S3, we execute the stanza creation command locally on the database host:
```bash
make stanza-create
```
This creates the schema files under the `/demo-s3` folder in your MinIO bucket. You can verify this by visiting `http://localhost:9001` in your browser (username: `minioadmin` / password: `minioadmin`) and looking inside the `pgbackrest` bucket!

### Step 3: Run Validation
Verify the S3 archiving and database connections:
```bash
make check
```

### Step 4: Perform a Baseline Backup
1. **Insert initial data** (Time T1):
   ```bash
   docker exec -u postgres pg-primary-s3 psql -c "
       CREATE TABLE test_table (id serial PRIMARY KEY, val text);
       INSERT INTO test_table (val) VALUES ('Initial data T1');
   "
   ```

2. **Force a WAL switch**:
   ```bash
   docker exec -u postgres pg-primary-s3 psql -c "SELECT pg_switch_wal();"
   ```

3. **Take a Full Backup**:
   ```bash
   make backup
   ```

### Step 5: Write "Good" Data & Grab Target Timestamp
1. **Insert new data** (Time T2) that we want to keep:
   ```bash
   docker exec -u postgres pg-primary-s3 psql -c "INSERT INTO test_table (val) VALUES ('Good data T2');"
   ```

2. **Force another WAL switch**:
   ```bash
   docker exec -u postgres pg-primary-s3 psql -c "SELECT pg_switch_wal();"
   ```

3. **Retrieve and record the current time**:
   Query the database to get the exact timestamp. This will serve as our recovery target timestamp.
   ```bash
   docker exec -u postgres pg-primary-s3 psql -t -A -c "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS.US') || '+00';"
   ```
   *Copy this timestamp! (e.g. `2026-07-10 18:30:45.123456+00`)*

### Step 6: The Disaster (`DROP TABLE`)
Simulate a user error by dropping the critical table (Time T3):
```bash
docker exec -u postgres pg-primary-s3 psql -c "DROP TABLE test_table;"
```
Verify the table is gone:
```bash
docker exec -u postgres pg-primary-s3 psql -c "SELECT * FROM test_table;"
# Output: ERROR: relation "test_table" does not exist
```

To ensure pgBackRest can replay up to the disaster point, we force one more WAL switch so the WAL containing the `DROP TABLE` statement gets archived to S3:
```bash
docker exec -u postgres pg-primary-s3 psql -c "SELECT pg_switch_wal();"
```

---

## 💥 Point-in-Time Recovery (PITR) Execution

We want to restore the database to the state it was in at **Time T2**, right before the `DROP TABLE` was executed.

### Step 1: Run the PITR Restore
Run the restore target with the copied timestamp:
```bash
make restore-pitr TARGET_TIME="<YOUR_COPIED_TIMESTAMP>"
```
What is this doing under the hood?
1. Stops the PostgreSQL server.
2. Deletes all files in the local data directory `/var/lib/postgresql/16/main`.
3. Downloads the files from the S3 full backup.
4. Generates a `postgresql.auto.conf` file containing:
   - `restore_command = 'pgbackrest --stanza=demo archive-get %f %p'`
   - `recovery_target_time = '<YOUR_COPIED_TIMESTAMP>'`
5. Creates a `recovery.signal` file in the data directory. This file signals to PostgreSQL 16 that it must start up in recovery mode.

### Step 2: Start and Monitor Recovery
PostgreSQL starts up. Since `recovery.signal` is present, it begins replaying WAL logs. Because it doesn't have the WAL logs locally (we wiped the data directory), it executes the `restore_command`. 
This command calls `pgbackrest` to pull the WAL files on-demand from S3!

PostgreSQL replays the logs up to the exact millisecond specified by `recovery_target_time`, then stops replaying, deletes the `recovery.signal` file, and opens the database for normal write connections.

### Step 3: Verify the Restored Data
Run a query to verify that the table has been restored and contains the data up to T2:
```bash
docker exec -u postgres pg-primary-s3 psql -c "SELECT * FROM test_table;"
```
If successful, you will see both records:
```
 id |       val        
----+------------------
  1 | Initial data T1
  2 | Good data T2
```

---

## 🧹 Cleanup
Stop the lab and clean the volumes:
```bash
make down
```

---

## 💡 Key Takeaways
1. **Direct Cloud Storage**: pgBackRest can speak S3, GCS, and Azure API natively, meaning database hosts don't require an intermediate SSH repository server in cloud environments.
2. **On-Demand WAL Replay**: During recovery, PostgreSQL pulls WAL files from S3 one-by-one as it needs them, using the `restore_command` configured by pgBackRest.
3. **Millisecond Accuracy**: PITR allows recovering from logical data loss (like drops, deletes, or truncates) by specifying the target time down to the microsecond.
