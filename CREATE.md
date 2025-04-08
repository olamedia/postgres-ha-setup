Okay, let's design a `docker-compose.yaml` file focusing on PostgreSQL with availability (via replication), web administration (pgAdmin), automated backups (pgBackRest), persistent data on the host filesystem, and components chosen with scalability in mind.

This setup uses:

1.  **PostgreSQL (Official Image):** For the database engine. We'll set up a primary and a replica.
2.  **pgAdmin4 (Official Image):** For browser-based administration.
3.  **pgBackRest (Community Image/Custom Build):** A powerful open-source backup and restore tool specifically for PostgreSQL. We'll use a pre-built image or provide instructions.
4.  **PgBouncer (Bitnami/Community Image):** A lightweight connection pooler, essential for handling many connections efficiently when scaling application servers.
5.  **Docker Compose:** To define and run the multi-container application.
6.  **Host Mounted Volumes:** For data, configuration, and backups, as requested.
7.  **.env File:** To manage secrets and configuration easily across environments.

**Assumptions:**

*   You have Docker and Docker Compose installed.
*   You are running this on a Linux-like host system (filesystem paths might need adjustment for Windows/macOS).
*   The design uses streaming replication for availability (read scaling + warm standby). True automatic failover typically requires external tooling (like Patroni, HAProxy, Keepalived) or an orchestrator (like Kubernetes) which is beyond a single `docker-compose.yaml` file for *hundreds* of servers but this setup provides the building blocks.

---

**1. Project Structure:**

Create the following directory structure:

```
postgres-ha-setup/
├── docker-compose.yaml
├── .env                     # <-- IMPORTANT: Store secrets here, DO NOT COMMIT
├── data/
│   ├── primary/
│   └── replica/
├── config/
│   ├── primary/
│   │   ├── postgresql.conf  # Primary specific config
│   │   └── pg_hba.conf      # Primary specific HBA rules
│   └── replica/
│       ├── postgresql.conf  # Replica specific config (hot_standby=on)
│       ├── pg_hba.conf      # Replica specific HBA rules
│       └── entrypoint-replica.sh # Script to initialize replica (chmod +x)
├── pgbouncer/
│   ├── pgbouncer.ini        # PgBouncer config
│   └── userlist.txt         # PgBouncer authentication
├── pgbackrest/
│   ├── conf/
│   │   └── pgbackrest.conf  # pgBackRest config
│   ├── log/
│   └── repo/                # Backup repository location
└── pgadmin-data/            # pgAdmin persistent data
```

---

**2. `.env` File (Create this file next to `docker-compose.yaml`)**

```dotenv
# WARNING: Secure this file properly!
# PostgreSQL Credentials
POSTGRES_USER=myuser
POSTGRES_PASSWORD=mysecretpassword          # Choose a strong password
POSTGRES_DB=mydatabase
REPLICATION_USER=replicator
REPLICATION_PASSWORD=replsecretpassword     # Choose a strong password

# pgAdmin Credentials
PGADMIN_DEFAULT_EMAIL=admin@example.com
PGADMIN_DEFAULT_PASSWORD=adminsecretpassword # Choose a strong password

# PgBouncer - Use the same DB user/pass for simplicity or dedicated ones
PGBOUNCER_USER=${POSTGRES_USER}
PGBOUNCER_PASSWORD=${POSTGRES_PASSWORD}

# pgBackRest - Set a passphrase for repository encryption (optional but recommended)
# PGBACKREST_REPO1_CIPHER_PASS=backrestsecretpassphrase

# Host paths (Optional - you can override defaults here if needed)
# DATA_PATH_PRIMARY=./data/primary
# DATA_PATH_REPLICA=./data/replica
# PGBACKREST_REPO_PATH=./pgbackrest/repo
# PGADMIN_DATA_PATH=./pgadmin-data
```

*   **IMPORTANT:** Set strong, unique passwords for `POSTGRES_PASSWORD`, `REPLICATION_PASSWORD`, and `PGADMIN_DEFAULT_PASSWORD`.
*   Add `PGBACKREST_REPO1_CIPHER_PASS` if you want encrypted backups.

---

**3. Configuration Files:**

**(a) `config/primary/postgresql.conf` (Minimal example, add your tuning):**

```ini
# Basic settings - Inherits defaults from Docker image
listen_addresses = '*'
max_connections = 100

# Replication Settings
wal_level = replica             # Required for replication
max_wal_senders = 5             # Number of replication connections
wal_keep_size = '512MB'         # Min size of WAL files to keep for replicas (adjust based on load/latency)
# Optional: archive_mode = on
# Optional: archive_command = '...' # Needed for PITR with pgBackRest if not using WAL shipping via replication slots

# pgBackRest requirements (if using archive push)
# archive_mode = on
# archive_command = 'pgbackrest --stanza=main archive-push %p'

# Logging (Example)
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/postgresql' # Mapped volume recommended for production logs
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_statement = 'ddl'

# Include pgBackRest generated config (optional, depends on pgBackRest config method)
# include_if_exists = '/etc/pgbackrest/pgbackrest-archive.conf'
```

**(b) `config/primary/pg_hba.conf`:**

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Allow replication connections from the replica node(s)
host    replication     replicator      all                     scram-sha-256

# Allow connections from pgAdmin, PgBouncer, and potentially apps on the docker network
host    all             all             all                     scram-sha-256

# Default local connections
local   all             all                                     peer # Or scram-sha-256 if needed
host    all             postgres        127.0.0.1/32            scram-sha-256 # For healthchecks etc.
```

**(c) `config/replica/postgresql.conf` (Minimal example):**

```ini
# Inherits defaults, primarily acts as standby
listen_addresses = '*'
max_connections = 100           # Can be higher for read scaling if needed

# Standby Settings
hot_standby = on                # Allow read-only queries on standby

# Replication Settings (must match primary)
wal_level = replica
max_wal_senders = 5
wal_keep_size = '512MB'         # Should match primary or be irrelevant if using slots

# Primary connection info will be in standby.signal (or recovery.conf for older PG)
# primary_conninfo = 'host=db-primary port=5432 user=replicator password=...' # Handled by entrypoint script
# primary_slot_name = 'replica_slot' # Optional: Use replication slots for reliability

# Logging (Similar to primary)
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-replica-%Y-%m-%d_%H%M%S.log'
log_statement = 'ddl'
```

**(d) `config/replica/pg_hba.conf`:**

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Allow connections from pgAdmin, PgBouncer (for reads), and apps on the docker network
host    all             all             all                     scram-sha-256

# Default local connections
local   all             all                                     peer
host    all             postgres        127.0.0.1/32            scram-sha-256
```

**(e) `config/replica/entrypoint-replica.sh` (Make executable: `chmod +x config/replica/entrypoint-replica.sh`):**

```bash
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
```
*Note: This script assumes PG12+. For older versions, `-R` creates `recovery.conf` instead of `standby.signal`, and you'd configure `standby_mode = 'on'` and `primary_conninfo` inside `recovery.conf`.*

**(f) `pgbouncer/pgbouncer.ini`:**

```ini
[databases]
; Mapped database name = connection string to actual database
; Use service names from docker-compose
mydatabase = host=db-primary port=5432 dbname=mydatabase auth_user=pgbouncer_auth

; Example for read replica pool (connect apps here for read scaling)
; mydatabase_read = host=db-replica port=5432 dbname=mydatabase auth_user=pgbouncer_auth

[pgbouncer]
listen_addr = *
listen_port = 6432

auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
; For SCRAM, PgBouncer needs to authenticate itself to lookup user credentials
; Create a user on the primary DB: CREATE USER pgbouncer_auth WITH PASSWORD '...'; GRANT CONNECT ON DATABASE mydatabase TO pgbouncer_auth;
auth_user = pgbouncer_auth # User defined in databases section above

admin_users = myuser       # DB users who can connect to pgbouncer console
stats_users = myuser       # DB users who can view stats

pool_mode = session        # Or transaction
server_reset_query = DISCARD ALL
max_client_conn = 1000     # Max total client connections
default_pool_size = 20     # Default connections per pool

# Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
```
*   **Important:** You need to create the `pgbouncer_auth` user in your primary database manually after it starts: `CREATE USER pgbouncer_auth WITH PASSWORD 'some_internal_password'; GRANT CONNECT ON DATABASE mydatabase TO pgbouncer_auth;`

**(g) `pgbouncer/userlist.txt` (Format: `"username" "password_hash"` - Use SCRAM hash):**

```
# Use scram-sha-256 hashes. Generate them on the primary DB:
# SELECTCONCAT('"', usename, '" "', rolpassword, '"') FROM pg_shadow WHERE usename = 'myuser';
# Replace the password below with the actual SCRAM hash from the DB.
"myuser" "SCRAM-SHA-256$..."
# Add other application users here
```
*   **Get the hash:** After starting the primary, connect using `psql` and run `SELECT rolpassword FROM pg_shadow WHERE usename = 'myuser';`. Copy the *entire* output (including `SCRAM-SHA-256$...`) into the `userlist.txt`.

**(h) `pgbackrest/conf/pgbackrest.conf`:**

```ini
[global]
repo1-path=/pgbackrest-repo # Path inside the container where backups are stored
repo1-retention-full=2      # Keep 2 full backups
log-level-file=info
start-fast=y                # Use checkpoints for faster start after backup

# Optional: Encrypt the repository
# repo1-cipher-type=aes-256-cbc
# repo1-cipher-pass= # Use env var PGBACKREST_REPO1_CIPHER_PASS

[main]                      # Stanza name - should be consistent
pg1-path=/var/lib/postgresql/data # Path to PGDATA on the primary container
pg1-host=db-primary         # Primary hostname (service name)
pg1-port=5432
pg1-user=postgres           # Use postgres superuser or dedicated backup user
# pg1-host-user=postgres    # OS user on the pg host container (usually postgres)

# If you need to back up the replica too (optional, usually back up primary)
# pg2-path=/var/lib/postgresql/data # Path to PGDATA on replica
# pg2-host=db-replica
# pg2-port=5432
# pg2-user=postgres
# pg2-host-user=postgres
```
*   **User:** Using the `postgres` superuser is easiest for setup. For production, create a dedicated `backup_user` with necessary privileges.
*   **Connection:** pgBackRest needs to connect to the database *and* potentially execute commands on the DB host OS (often via SSH, but here we simplify by running commands *inside* the DB container via `docker exec`).

---

**4. `docker-compose.yaml`**

```yaml
version: '3.8'

services:
  db-primary:
    image: postgres:15 # Use a specific version
    container_name: db-primary
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      # Use scram-sha-256 for security
      POSTGRES_INITDB_ARGS: "--auth-host=scram-sha-256 --auth-local=scram-sha-256"
      POSTGRES_HOST_AUTH_METHOD: scram-sha-256
      PGDATA: /var/lib/postgresql/data/pgdata # Explicitly set PGDATA inside container
    volumes:
      - ./data/primary:/var/lib/postgresql/data/pgdata # Mount data to host
      - ./config/primary/postgresql.conf:/etc/postgresql/postgresql.conf # Custom config
      - ./config/primary/pg_hba.conf:/etc/postgresql/pg_hba.conf # Custom HBA
      # Shared volumes for pgBackRest (simpler than SSH inside Docker for this setup)
      - ./pgbackrest/log:/var/log/pgbackrest
      - ./pgbackrest/conf:/etc/pgbackrest
      - ./pgbackrest/repo:/pgbackrest-repo
    ports:
      # Only expose if needed directly from host, otherwise use pgbouncer/pgadmin
      # - "127.0.0.1:5432:5432"
      - "5432" # Expose only to other containers on the network by default
    networks:
      - db-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: postgres -c config_file=/etc/postgresql/postgresql.conf -c hba_file=/etc/postgresql/pg_hba.conf

  db-replica:
    image: postgres:15 # Must match primary version
    container_name: db-replica
    restart: unless-stopped
    environment:
      # NO POSTGRES_DB/USER/PASSWORD here, it gets data via replication!
      REPLICATION_USER: ${REPLICATION_USER}
      REPLICATION_PASSWORD: ${REPLICATION_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata # Explicit PGDATA
    volumes:
      - ./data/replica:/var/lib/postgresql/data/pgdata # Separate data volume
      - ./config/replica/postgresql.conf:/etc/postgresql/postgresql.conf
      - ./config/replica/pg_hba.conf:/etc/postgresql/pg_hba.conf
      - ./config/replica/entrypoint-replica.sh:/usr/local/bin/entrypoint-replica.sh # Custom entrypoint
      # Shared volumes for pgBackRest (if restoring to replica or using it for info)
      - ./pgbackrest/log:/var/log/pgbackrest
      - ./pgbackrest/conf:/etc/pgbackrest
      - ./pgbackrest/repo:/pgbackrest-repo
    ports:
      # Only expose if needed directly from host for read-only tests
      # - "127.0.0.1:5433:5432"
      - "5432" # Expose only to other containers
    networks:
      - db-network
    depends_on:
      db-primary:
        condition: service_healthy # Wait for primary healthcheck
    entrypoint: ["/usr/local/bin/entrypoint-replica.sh"] # Use custom script
    command: postgres -c config_file=/etc/postgresql/postgresql.conf -c hba_file=/etc/postgresql/pg_hba.conf

  pgbouncer:
    image: bitnami/pgbouncer:latest # Well-maintained pgbouncer image
    container_name: pgbouncer
    restart: unless-stopped
    environment:
      # These are often used by the image's scripts, but main config is via files
      PGBOUNCER_AUTH_TYPE: scram-sha-256
      PGBOUNCER_DATABASE: ${POSTGRES_DB} # Needs to know a target DB
      PGBOUNCER_AUTH_USER: pgbouncer_auth # User specified in pgbouncer.ini for internal auth
      PGBOUNCER_AUTH_QUERY: "SELECT usename, rolpassword FROM pg_shadow WHERE usename=$1" # Needed for SCRAM
      # Define credentials for the PGBOUNCER_AUTH_USER here if image requires it
      # PGBOUNCER_AUTH_USER_USERNAME: pgbouncer_auth
      # PGBOUNCER_AUTH_USER_PASSWORD: 'the_internal_password_you_set'
    volumes:
      - ./pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini
      - ./pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt
    ports:
      - "6432:6432" # Standard PgBouncer port - APPS CONNECT HERE
    networks:
      - db-network
    depends_on:
      - db-primary # Needs primary to connect

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: pgadmin
    restart: unless-stopped
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_DEFAULT_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_DEFAULT_PASSWORD}
      PGADMIN_LISTEN_PORT: 80 # Port inside the container
    volumes:
      - ./pgadmin-data:/var/lib/pgadmin # Persist pgAdmin config/servers
    ports:
      - "8080:80" # Access pgAdmin via http://localhost:8080
    networks:
      - db-network
    depends_on:
      - db-primary # Wait for primary before starting

  pgbackrest:
    # Use official or community image - might need features like SSH if not using shared volumes fully
    image: pgbackrest/pgbackrest:latest
    container_name: pgbackrest
    # This container is primarily for running commands via 'docker exec'
    # Or you could add cron and run scheduled backups from here
    restart: unless-stopped
    volumes:
      - ./pgbackrest/conf:/etc/pgbackrest
      - ./pgbackrest/log:/var/log/pgbackrest
      - ./pgbackrest/repo:/pgbackrest-repo # Backup data on host
      # Mount primary/replica data dirs IF needed for local operations (less common)
      # - ./data/primary:/var/lib/postgresql/data/primary:ro
      # - ./data/replica:/var/lib/postgresql/data/replica:ro
    environment:
      # Pass passphrase if using encrypted repo
      PGBACKREST_REPO1_CIPHER_PASS: ${PGBACKREST_REPO1_CIPHER_PASS:-} # Optional from .env
    networks:
      - db-network
    depends_on:
      - db-primary
    # Keep container running - used via exec or internal cron
    command: ["tail", "-f", "/dev/null"] # Simple way to keep it alive

networks:
  db-network:
    driver: bridge

volumes:
  # Although we map to host paths, defining them here helps Docker manage them
  # You can remove these if you ONLY want direct host paths without Docker volume metadata
  pgdata-primary:
    driver_opts:
      type: none
      device: ${PWD}/data/primary # Use absolute path expansion
      o: bind
  pgdata-replica:
    driver_opts:
      type: none
      device: ${PWD}/data/replica
      o: bind
  pgadmin-data:
    driver_opts:
      type: none
      device: ${PWD}/pgadmin-data
      o: bind
  pgbackrest-repo:
    driver_opts:
      type: none
      device: ${PWD}/pgbackrest/repo
      o: bind
# Note: Volume definitions using driver_opts like this might be less portable than
# simple host mounts defined directly in the service volume section. The example above
# uses direct host mounts in the services for clarity, as requested.
# Remove the 'volumes:' block at the end if using only direct host paths in services.
```

---

**5. Setup and Usage:**

1.  **Create Directories:** Create the directory structure shown in step 1.
2.  **Create `.env`:** Create the `.env` file and fill in strong secrets.
3.  **Create Config Files:** Create the `postgresql.conf`, `pg_hba.conf`, `entrypoint-replica.sh`, `pgbouncer.ini`, `userlist.txt`, and `pgbackrest.conf` files with the content provided above.
    *   **Make script executable:** `chmod +x config/replica/entrypoint-replica.sh`
4.  **Permissions:** Ensure the directories you created (`data`, `pgbackrest`, `pgadmin-data`) are writable by the user ID that Docker runs the container processes as (often `postgres`, ID `999` or `70`, or `root` depending on the image/setup). You might need `sudo chown -R 999:999 data/ pgbackrest/ pgadmin-data/` or similar, depending on your system and the specific images. This can be tricky with host mounts. *Using named Docker volumes avoids most permission issues.*
5.  **Start:** `docker-compose up -d`
6.  **Initial Setup (After `up -d`):**
    *   **Create Replication User:** Connect to the *primary* DB (e.g., via pgAdmin or `docker-compose exec db-primary psql -U myuser -d mydatabase`) and run:
        ```sql
        CREATE USER replicator WITH REPLICATION LOGIN PASSWORD 'replsecretpassword'; -- Use password from .env
        -- Optional but Recommended: Create a replication slot
        -- SELECT pg_create_physical_replication_slot('replica_slot');
        ```
    *   **Create PgBouncer Auth User:** On the *primary* DB:
        ```sql
        CREATE USER pgbouncer_auth WITH PASSWORD 'some_internal_password'; -- Use a secure internal password
        GRANT CONNECT ON DATABASE mydatabase TO pgbouncer_auth;
        ```
    *   **Get SCRAM Hash for PgBouncer `userlist.txt`:** On the *primary* DB:
        ```sql
        -- Make sure the user exists and has a SCRAM password set (done by default init)
        SELECT rolpassword FROM pg_shadow WHERE usename = 'myuser';
        ```
        Copy the output hash into `pgbouncer/userlist.txt`. Restart pgbouncer: `docker-compose restart pgbouncer`.
    *   **Initialize pgBackRest Stanza:** Execute *inside* the **primary** container:
        ```bash
        docker-compose exec db-primary pgbackrest --stanza=main --log-level-console=info stanza-create
        ```
        Then check the configuration on the **pgbackrest** container:
        ```bash
        docker-compose exec pgbackrest pgbackrest --stanza=main --log-level-console=info check
        ```
        *(Troubleshooting: This step requires pgBackRest config to be correct on both containers and connectivity. Ensure `pg1-path` in `pgbackrest.conf` matches the `$PGDATA` in the primary container.)*
7.  **Run First Backup:**
    ```bash
    docker-compose exec pgbackrest pgbackrest --stanza=main --log-level-console=info backup --type=full
    ```
8.  **Access Services:**
    *   **pgAdmin:** `http://localhost:8080` (Login with `.env` credentials)
    *   **Database (via PgBouncer):** Host: `localhost`, Port: `6432`, User/Pass/DB from `.env`. **This is how applications should connect.**
    *   **Database (Primary Direct - for admin):** Host: `localhost`, Port: `5432` (if exposed), User/Pass/DB from `.env`.
    *   **Database (Replica Direct - for read tests):** Host: `localhost`, Port: `5433` (if exposed), User/Pass/DB from `.env`.

**Scalability Considerations Addressed:**

*   **Containerization:** Each component is isolated.
*   **Configuration:** Secrets and parameters are externalized (`.env`). Config files are mounted.
*   **Replication:** Provides read scaling and a warm standby. More replicas can potentially be added (adjust `max_wal_senders`).
*   **Connection Pooling:** PgBouncer significantly reduces connection overhead on PostgreSQL, crucial for handling many application clients.
*   **Backup:** pgBackRest is designed for large databases and provides PITR capabilities.
*   **Data Volumes:** Separated data volumes allow independent management/backup of the host filesystem data.

**Scaling to Hundreds of Servers:**

*   This `docker-compose.yaml` defines the *building blocks*.
*   For actual large-scale deployment, you would use an orchestrator like **Kubernetes** or **Nomad**.
*   The orchestrator would manage:
    *   Deploying these container definitions across multiple physical/virtual servers.
    *   Service discovery (how containers find each other across hosts).
    *   Load balancing (e.g., using HAProxy or Kubernetes Services in front of PgBouncer or read replicas).
    *   Automated failover (using tools like Patroni integrated with the orchestrator's state management like etcd/Consul).
    *   Persistent Volume Claims (mapping container volumes to network storage like Ceph, NFS, or cloud provider disks instead of local host paths).
    *   Centralized logging and monitoring.

This setup provides a solid, FOSS foundation that can be adapted and deployed using more advanced orchestration tools when you need to scale beyond a single host or small cluster. Remember to secure your `.env` file and host directories appropriately.