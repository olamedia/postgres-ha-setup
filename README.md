# PostgreSQL HA Demo with Docker Compose

This project provides a local development and testing environment for a PostgreSQL setup featuring High Availability (HA) components, using only free and open-source software orchestrated with Docker Compose.

It demonstrates a configuration including:
*   **PostgreSQL Primary Server:** Handles writes and acts as the replication source.
*   **PostgreSQL Streaming Replica:** Provides read scaling and a warm standby for failover scenarios.
*   **PgBouncer:** Lightweight connection pooling to optimize database connections from applications.
*   **pgBackRest:** Robust backup and restore solution tailored for PostgreSQL.
*   **pgAdmin4:** Web-based administration GUI for managing the databases.
*   **Host Volume Persistence:** Ensures data, configurations, and backups persist across container restarts.

**Goal:** To offer a convenient local setup that mimics essential aspects of a production-ready, scalable PostgreSQL deployment, facilitating development and testing of applications requiring a resilient database backend.

---

## Table of Contents

*   [Features](#features)
*   [Directory Structure](#directory-structure)
*   [Prerequisites](#prerequisites)
*   [Quick Start](#quick-start)
*   [Configuration](#configuration)
*   [Usage](#usage)
    *   [Connecting to the Database](#connecting-to-the-database)
    *   [Accessing pgAdmin](#accessing-pgadmin)
    *   [Performing Backups](#performing-backups)
*   [Detailed Documentation](#detailed-documentation)
*   [Administration](#administration)
*   [Scaling](#scaling)
*   [Security Considerations](#security-considerations)
*   [Limitations](#limitations)
*   [Contributing](#contributing)
*   [License](#license)

---

## Features

*   **PostgreSQL 15** (or specify version used) Primary-Replica setup.
*   Asynchronous Streaming Replication for HA and read scaling.
*   Connection Pooling with PgBouncer.
*   Browser-based Administration via pgAdmin4.
*   Integrated Backup & Restore using pgBackRest.
*   Persistent data storage using host-mounted volumes.
*   Configuration managed via external files and `.env` for secrets.
*   Designed with scalability concepts in mind (though Docker Compose is single-host).

## Directory Structure

```
.
├── docker-compose.yaml           # Main Docker Compose definition
├── .env.example                  # Example environment variables (Copy to .env)
├── .env                          # Environment variables (Secrets - DO NOT COMMIT)
├── data/                         # Persisted data (mounted from host)
│   ├── primary/                  # Primary DB data
│   └── replica/                  # Replica DB data
├── config/                       # Configuration files
│   ├── primary/
│   │   ├── postgresql.conf       # Primary DB configuration
│   │   └── pg_hba.conf           # Primary DB access rules
│   └── replica/
│       ├── postgresql.conf       # Replica DB configuration
│       ├── pg_hba.conf           # Replica DB access rules
│       └── entrypoint-replica.sh # Replica initialization script
├── pgbouncer/                    # PgBouncer configuration
│   ├── pgbouncer.ini             # Main PgBouncer config
│   └── userlist.txt              # PgBouncer user authentication (SCRAM hashes)
├── pgbackrest/                   # pgBackRest configuration and data
│   ├── conf/
│   │   └── pgbackrest.conf       # pgBackRest configuration
│   ├── log/                      # pgBackRest logs (mounted)
│   └── repo/                     # pgBackRest backup repository (mounted)
├── pgadmin-data/                 # Persisted pgAdmin data (servers, settings)
├── INSTALL.md                    # Detailed installation and setup guide
├── ADMIN.md                      # System administration and monitoring guide
└── README.md                     # This file
```

## Prerequisites

*   **Docker:** Latest version installed ([Get Docker](https://docs.docker.com/get-docker/)).
*   **Docker Compose:** V2 recommended ([Install Docker Compose](https://docs.docker.com/compose/install/)).
*   **Git** (optional, for cloning).
*   **Operating System:** Linux recommended. macOS/Windows may require adjustments (especially paths and permissions).
*   Basic familiarity with the command line/terminal.

## Quick Start

1.  **Clone the Repository:**
    ```bash
    git clone <your-repo-url>
    cd postgres-ha-setup
    ```
2.  **Create `.env` File:** Copy the example and customize it with **strong passwords**.
    ```bash
    cp .env.example .env
    nano .env # Or use your preferred editor
    ```
    *   **CRITICAL:** Secure the `POSTGRES_PASSWORD`, `REPLICATION_PASSWORD`, and `PGADMIN_DEFAULT_PASSWORD`.
    *   Optionally configure `PGBACKREST_REPO1_CIPHER_PASS` for encrypted backups.
3.  **Adjust Permissions (Linux Host):** Ensure host directories are writable by the container user (often UID `999` or `70`). **Use with caution.**
    ```bash
    # Check postgres image documentation for the correct UID if unsure
    # sudo chown -R 999:999 data/ pgbackrest/ pgadmin-data/
    # Or more permissively (less secure):
    # sudo chmod -R 777 data/ pgbackrest/ pgadmin-data/
    ```
    *Alternatively, switch to named volumes in `docker-compose.yaml` to avoid host permission issues.*
4.  **Build and Start Containers:**
    ```bash
    docker-compose up -d
    ```
5.  **Perform Post-Start Initialization:** (Run these commands after containers are up)
    *   Create Replication User:
        ```bash
        docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<< "CREATE USER ${REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';"
        ```
    *   Create PgBouncer Auth User (Use a secure internal password):
        ```bash
        PGBOUNCER_INTERNAL_PASS='a_secure_internal_password' # Choose a strong password
        docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<< "CREATE USER pgbouncer_auth WITH PASSWORD '${PGBOUNCER_INTERNAL_PASS}'; GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO pgbouncer_auth; GRANT pg_read_all_settings TO pgbouncer_auth;"
        ```
    *   Generate SCRAM Hash for `userlist.txt`:
        ```bash
        HASH=$(docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT rolpassword FROM pg_shadow WHERE usename = '${POSTGRES_USER}';")
        echo "\"${POSTGRES_USER}\" \"${HASH}\"" > pgbouncer/userlist.txt
        docker-compose restart pgbouncer
        ```
    *   Initialize pgBackRest Stanza:
        ```bash
        docker-compose exec db-primary pgbackrest --stanza=main --log-level-console=info stanza-create
        docker-compose exec pgbackrest pgbackrest --stanza=main --log-level-console=info check
        ```
6.  **Run Initial Backup:**
    ```bash
    docker-compose exec pgbackrest pgbackrest --stanza=main --type=full backup
    ```

For detailed setup steps, please refer to the [**Installation Guide (INSTALL.md)**](./INSTALL.md).

## Configuration

*   **Environment Variables:** Core credentials and settings are managed in the `.env` file. **Never commit `.env` to version control.** See `.env.example`.
*   **PostgreSQL:** Configuration files are located in [`config/primary/`](./config/primary/) and [`config/replica/`](./config/replica/).
    *   [`config/primary/postgresql.conf`](./config/primary/postgresql.conf)
    *   [`config/primary/pg_hba.conf`](./config/primary/pg_hba.conf)
    *   [`config/replica/postgresql.conf`](./config/replica/postgresql.conf)
    *   [`config/replica/pg_hba.conf`](./config/replica/pg_hba.conf)
*   **PgBouncer:** Configuration in [`pgbouncer/`](./pgbouncer/).
    *   [`pgbouncer/pgbouncer.ini`](./pgbouncer/pgbouncer.ini)
    *   [`pgbouncer/userlist.txt`](./pgbouncer/userlist.txt) (Contains SCRAM hashes for users)
*   **pgBackRest:** Configuration in [`pgbackrest/conf/`](./pgbackrest/conf/).
    *   [`pgbackrest/conf/pgbackrest.conf`](./pgbackrest/conf/pgbackrest.conf)

Changes to most configuration files require a reload or restart of the respective service. See the [Administration Guide (ADMIN.md)](./ADMIN.md) for details.

## Usage

### Connecting to the Database

*   **Applications:** Connect via PgBouncer.
    *   Host: `localhost` (or `pgbouncer` if connecting from another container on the same Docker network)
    *   Port: `6432`
    *   User/Password/Database: As defined in your `.env` file (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`).
*   **Direct Admin Access (Primary):**
    *   Host: `localhost` (or `db-primary`)
    *   Port: `5432` (or use `docker-compose exec db-primary psql ...`)
*   **Direct Read Access (Replica):**
    *   Host: `localhost` (or `db-replica`)
    *   Port: `5432` (or use `docker-compose exec db-replica psql ...`)

### Accessing pgAdmin

*   Navigate to `http://localhost:8080` in your web browser.
*   Log in using the credentials from your `.env` file (`PGADMIN_DEFAULT_EMAIL`, `PGADMIN_DEFAULT_PASSWORD`).
*   Add servers using the connection details above (use service names like `pgbouncer`, `db-primary`, `db-replica` as the host when configuring servers within pgAdmin).

### Performing Backups

Use `docker-compose exec` to run pgBackRest commands:

```bash
# Full Backup
docker-compose exec pgbackrest pgbackrest --stanza=main --type=full backup

# Incremental Backup
docker-compose exec pgbackrest pgbackrest --stanza=main --type=incr backup

# Check Backup Info
docker-compose exec pgbackrest pgbackrest --stanza=main info
```
Backups are stored in `./pgbackrest/repo/` on the host.

## Detailed Documentation

*   [**Installation Guide (INSTALL.md)**](./INSTALL.md): Step-by-step instructions for setting up the environment locally.
*   [**Administration Guide (ADMIN.md)**](./ADMIN.md): Covers monitoring, routine tasks, configuration management, user management, backup/restore, and troubleshooting.

## Administration

For day-to-day monitoring, maintenance, user management, and troubleshooting, please consult the [**Administration Guide (ADMIN.md)**](./ADMIN.md).

## Scaling

This Docker Compose setup provides the building blocks but is limited to a single host. For scaling to multiple servers, orchestration tools like Kubernetes are required, typically using components like Patroni for automated failover. See the [Scaling Considerations Chapter](./INSTALL.md#chapter-2-scaling-considerations) in the Installation Guide for more details.

## Security Considerations

*   **Protect the `.env` file.**
*   Use strong, unique passwords.
*   Review and restrict access in `pg_hba.conf` files.
*   Limit exposed ports in `docker-compose.yaml`.
*   Consider running pgAdmin behind a reverse proxy with HTTPS for production-like scenarios.
*   Enable pgBackRest repository encryption for backups at rest.

See the Security section in the [Administration Guide](./ADMIN.md#12-security-considerations) for more details.

## Limitations

*   This setup uses **Docker Compose**, which is intended for single-host environments. It does *not* provide automatic cross-host orchestration or failover.
*   **Failover is manual:** While a replica exists, promoting it requires manual steps described in the administration guide or external tooling (like Patroni in a Kubernetes setup).
*   **Host Volume Permissions:** Can be tricky depending on the host OS and Docker configuration.

## Contributing

Contributions, issues, and feature requests are welcome. Please open an issue or submit a pull request.

## License

[MIT License](./LICENSE)
