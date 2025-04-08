#!/bin/bash
set -e

# Check if data directory is empty
if [ -z "$(ls -A "$PGDATA")" ]; then
    echo "Data directory is empty. Initializing replica from primary..."

    # Wait for primary to be available
    until PGPASSWORD=$REPLICATION_PASSWORD pg_isready -h db-primary -p 5432 -U $REPLICATION_USER; do
      echo "Waiting for primary database to be ready..."
      sleep 2
    done
    echo "Primary database is ready."

    # Perform base backup
    echo "Running pg_basebackup..."
    PGPASSWORD=$REPLICATION_PASSWORD pg_basebackup \
        -h db-primary \
        -p 5432 \
        -U $REPLICATION_USER \
        -D "$PGDATA" \
        -Fp \
        -Xs \
        -P \
        -R # Creates standby.signal (PG12+) or recovery.conf

    # Adjust permissions if needed (Docker entrypoint usually handles this)
    # chown -R postgres:postgres "$PGDATA"
    # chmod 0700 "$PGDATA"

    echo "Replica initialized."
else
    echo "Data directory not empty. Assuming replica is already initialized or restarting."
    # Ensure standby.signal exists if restarting an initialized replica
    touch "$PGDATA/standby.signal" || true # PG12+
fi

# Start PostgreSQL using the default Docker entrypoint script
# This will pass control to the original postgres entrypoint
echo "Starting PostgreSQL replica..."
exec docker-entrypoint.sh postgres "$@"