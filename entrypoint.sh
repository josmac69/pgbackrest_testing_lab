#!/bin/bash
set -e

# Ensure permissions on ssh directories on start (ignore errors if read-only or not writable)
chown -R postgres:postgres /var/lib/postgresql/.ssh || true
chmod 700 /var/lib/postgresql/.ssh || true
chmod 600 /var/lib/postgresql/.ssh/* || true

# Ensure ownership of pgbackrest directories (since volumes might mount as root)
# Avoid recursive chown on /etc/pgbackrest which might contain read-only mounts
chown postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest /etc/pgbackrest || true
chmod 750 /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest /etc/pgbackrest || true

chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest || true
chmod -R 750 /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest || true

PGDATA="/var/lib/postgresql/16/main"

if [ "$NODE_TYPE" = "primary" ]; then
    # Start SSH daemon
    sudo /usr/sbin/sshd

    # Check if database is initialized
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        echo "Initializing database cluster..."
        mkdir -p "$PGDATA"
        chown -R postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"
        gosu postgres /usr/lib/postgresql/16/bin/initdb -D "$PGDATA" -U postgres --auth-local=peer --auth-host=scram-sha-256

        # Append pgBackRest and connection settings
        cat <<EOF >> "$PGDATA/postgresql.conf"
# pgBackRest configurations
archive_mode = on
archive_command = 'pgbackrest --stanza=demo archive-push %p'
max_wal_senders = 10
wal_level = replica
hot_standby = on
listen_addresses = '*'
EOF

        # Configure pg_hba.conf to allow replication and standard connections
        cat <<EOF > "$PGDATA/pg_hba.conf"
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             0.0.0.0/0               scram-sha-256
host    replication     replication_user 0.0.0.0/0               scram-sha-256
EOF

        # Start temp server to create replication user
        echo "Creating replication user..."
        gosu postgres /usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -c archive_mode=off" -w start
        gosu postgres psql -c "CREATE ROLE replication_user WITH REPLICATION LOGIN PASSWORD 'replica_password';"
        gosu postgres /usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -w stop
    fi

    # Start PostgreSQL
    echo "Starting PostgreSQL Primary..."
    gosu postgres /usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -l /var/lib/postgresql/postgresql.log start

    echo "Container ready. Keeping alive..."
    exec tail -f /dev/null

elif [ "$NODE_TYPE" = "standby" ]; then
    # Start SSH daemon
    sudo /usr/sbin/sshd

    # Wait for primary
    echo "Waiting for primary (pg-primary:5432) to start..."
    until pg_isready -h pg-primary -U postgres; do
        sleep 1
    done
    echo "Primary is online."

    # Bootstrap standby if data dir is empty
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        echo "Bootstrapping standby from primary..."
        mkdir -p "$PGDATA"
        chown -R postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"
        # Run pg_basebackup
        PGPASSWORD=replica_password gosu postgres pg_basebackup -h pg-primary -U replication_user -D "$PGDATA" -Fp -Xs -P -R
        
        # Configure standby configurations
        cat <<EOF >> "$PGDATA/postgresql.conf"
# Standby specific configurations
hot_standby = on
archive_mode = on
archive_command = 'pgbackrest --stanza=demo archive-push %p'
EOF
    fi

    # Start PostgreSQL
    echo "Starting PostgreSQL Standby..."
    gosu postgres /usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -l /var/lib/postgresql/postgresql.log start

    echo "Container ready. Keeping alive..."
    exec tail -f /dev/null

elif [ "$NODE_TYPE" = "repo" ]; then
    # Repository container: just run sshd in foreground
    echo "Starting pgBackRest repository server (sshd)..."
    exec /usr/sbin/sshd -D
else
    echo "Unknown NODE_TYPE: $NODE_TYPE. Starting shell..."
    exec /bin/bash
fi
