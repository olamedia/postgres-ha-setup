Okay, here is an administration manual focusing on the day-to-day operations, monitoring, and maintenance of the PostgreSQL HA Docker Compose system previously defined.

---

## Manual: Administering the PostgreSQL HA Docker Compose System

**Version:** 1.0
**Date:** 2025-04-08

**Table of Contents:**

1.  Introduction
2.  System Overview
3.  Prerequisites & Tools
4.  Core Operations (Using Docker Compose)
5.  Monitoring the System
    *   5.1 Overall Service Status
    *   5.2 Database Health (Primary & Replica)
    *   5.3 Replication Status
    *   5.4 PgBouncer Status & Connections
    *   5.5 Backup Status (pgBackRest)
    *   5.6 Host Filesystem Usage
6.  Routine Tasks
    *   6.1 Running Backups Manually
    *   6.2 Checking Logs
    *   6.3 Managing Disk Space
7.  Configuration Management
    *   7.1 Modifying PostgreSQL Configuration
    *   7.2 Modifying PgBouncer Configuration
8.  Database User Management
    *   8.1 Adding a New User
    *   8.2 Changing a User's Password
    *   8.3 Removing a User
9.  Backup and Restore Operations
    *   9.1 Performing Backups
    *   9.2 Restoring (Overview & Considerations)
10. Troubleshooting Common Issues
    *   10.1 Containers Not Starting
    *   10.2 Replication Lag / Replica Not Syncing
    *   10.3 Cannot Connect via PgBouncer
    *   10.4 Cannot Connect via pgAdmin
    *   10.5 Backup Failures
11. Updates and Maintenance
12. Security Considerations

---

### 1. Introduction

This manual provides guidance for administrators responsible for maintaining the Docker Compose-based PostgreSQL High Availability (HA) setup. It covers routine monitoring, maintenance tasks, configuration changes, user management, backup operations, and basic troubleshooting. This setup includes a primary PostgreSQL instance, a streaming replica, PgBouncer connection pooler, pgAdmin4 web interface, and pgBackRest for backups.

### 2. System Overview

*   **`db-primary`:** The main PostgreSQL server handling write operations and serving as the source for replication.
*   **`db-replica`:** A read-only replica receiving changes from `db-primary` via streaming replication. Provides read scaling and warm standby capability.
*   **`pgbouncer`:** A lightweight connection pooler. Applications should connect *through* PgBouncer (Port 6432 by default) to reduce connection overhead on the primary database.
*   **`pgadmin`:** A web-based GUI for managing PostgreSQL servers (accessible via port 8080 by default).
*   **`pgbackrest`:** Handles backup and restore operations. Backups are stored on the host filesystem (`./pgbackrest/repo`).
*   **Docker Compose:** Orchestrates the containers on a single host.
*   **Host Volumes:** Data (`./data/`), pgAdmin settings (`./pgadmin-data/`), and backups (`./pgbackrest/repo/`) are persisted on the host machine's filesystem.

### 3. Prerequisites & Tools

*   Access to the host machine running the Docker containers.
*   Terminal or SSH access to the host.
*   Docker and Docker Compose installed and running.
*   Familiarity with basic Docker Compose commands (`up`, `down`, `ps`, `logs`, `exec`).
*   Access credentials (from the `.env` file) for PostgreSQL and pgAdmin.
*   Web browser for accessing pgAdmin.
*   (Optional but Recommended) `psql` client installed on the host or used via `docker exec`.

### 4. Core Operations (Using Docker Compose)

All commands should be run from the directory containing the `docker-compose.yaml` file (`postgres-ha-setup/`).

*   **Check Status:** See running containers and their state.
    ```bash
    docker-compose ps
    ```
*   **View Logs (All Services):** Follow logs in real-time.
    ```bash
    docker-compose logs -f
    ```
*   **View Logs (Specific Service):**
    ```bash
    docker-compose logs -f db-primary
    docker-compose logs -f db-replica
    docker-compose logs -f pgbouncer
    # etc.
    ```
*   **Start Services:** Start containers in the background.
    ```bash
    docker-compose up -d
    ```
*   **Stop Services:** Stop containers without removing them. Data persists.
    ```bash
    docker-compose stop
    ```
*   **Restart Services:** Stop and then start containers.
    ```bash
    docker-compose restart # Restarts all services
    docker-compose restart db-primary pgbouncer # Restarts specific services
    ```
*   **Stop and Remove Containers:** Stops containers and removes them. Networks are usually removed too. **Data in host volumes is NOT deleted.**
    ```bash
    docker-compose down
    ```
*   **Execute Command in a Container:** Run a command inside a running container. Essential for many admin tasks.
    ```bash
    # Example: Run psql inside the primary database container
    docker-compose exec db-primary psql -U <username> -d <dbname>

    # Example: Run a pgbackrest command
    docker-compose exec pgbackrest pgbackrest --stanza=main info
    ```

### 5. Monitoring the System

Regular monitoring is crucial for ensuring availability and performance.

**5.1 Overall Service Status**
Use `docker-compose ps` to quickly check if all containers (`db-primary`, `db-replica`, `pgbouncer`, `pgadmin`, `pgbackrest`) are in the `Up` or `running` state.

**5.2 Database Health (Primary & Replica)**
*   **Using `pg_isready`:** Execute this from the host or another container to check basic connectivity.
    ```bash
    # Check Primary (via Docker exec)
    docker-compose exec db-primary pg_isready -h localhost -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB
    # Check Replica (via Docker exec)
    docker-compose exec db-replica pg_isready -h localhost -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB
    # Check via PgBouncer (from host, requires psql client)
    pg_isready -h localhost -p 6432 -U $POSTGRES_USER -d $POSTGRES_DB
    ```
    Look for output indicating the server is accepting connections.
*   **Using pgAdmin:** Connect to the primary (and optionally replica) servers. The dashboard provides basic health metrics (sessions, transactions, locks). Successful connection indicates basic health.

**5.3 Replication Status**
*   Connect to the **primary** database (`db-primary`) using `psql` or pgAdmin.
*   Run the following query:
    ```sql
    SELECT
        usename AS replication_user,
        client_addr AS replica_address,
        state,
        sent_lsn,
        write_lsn,
        flush_lsn,
        replay_lsn,
        write_lag,
        flush_lag,
        replay_lag,
        sync_state
    FROM pg_stat_replication;
    ```
*   **Key things to check:**
    *   An entry for the replica should exist.
    *   `state` should ideally be `streaming`.
    *   `*_lag` columns indicate delay. Small lags are normal, but consistently large or growing lags indicate potential network issues, heavy write load on the primary, or slow processing on the replica. `replay_lag` is often the most critical metric for data freshness on the replica.
    *   `sync_state` indicates if it's a potential synchronous replication candidate (usually `async` in this setup unless configured otherwise).

**5.4 PgBouncer Status & Connections**
*   **Connect to PgBouncer Admin Console:** Use `psql` to connect to the *special* `pgbouncer` database on the PgBouncer port (6432). You must connect as a user listed in `admin_users` in `pgbouncer.ini` (e.g., the main `POSTGRES_USER`).
    ```bash
    # From host (replace user/password)
    PGPASSWORD=$POSTGRES_PASSWORD psql -h localhost -p 6432 -U $POSTGRES_USER pgbouncer
    ```
*   **Useful PgBouncer Commands (run inside the psql console):**
    *   `SHOW STATS;`: View connection counts (clients active/waiting, servers active/idle), data transfer, query times per pool.
    *   `SHOW POOLS;`: Detailed information about each configured pool, including state, connection counts, and delays.
    *   `SHOW DATABASES;`: Check configured database connection strings.
    *   `SHOW CLIENTS;`: List currently connected clients.
    *   `SHOW SERVERS;`: List backend server connections managed by PgBouncer.
    *   `PAUSE <dbname | *>;`: Temporarily stop allowing new connections to a pool or all pools.
    *   `RESUME <dbname | *>;`: Allow connections again.
    *   `RELOAD;`: Reload `pgbouncer.ini` configuration and `userlist.txt`. Often needed after changes.
*   **Check Logs:** View PgBouncer logs for connection errors or issues:
    ```bash
    docker-compose logs pgbouncer
    ```

**5.5 Backup Status (pgBackRest)**
*   **Check Last Backup Status:** Use the `info` command:
    ```bash
    docker-compose exec pgbackrest pgbackrest --stanza=main info
    ```
    This shows available backup sets, timestamps, sizes, and WAL archive status. Check the `status` field (should be `ok`).
*   **Check Backup Logs:** Backups run via `docker exec` will output to the console. If run via cron inside the container, check the pgBackRest log files:
    ```bash
    docker-compose exec pgbackrest tail -f /var/log/pgbackrest/main-backup.log
    # Or check logs within the ./pgbackrest/log directory on the host
    ```

**5.6 Host Filesystem Usage**
Since data and backups are stored on the host, monitor disk space regularly.
*   Use standard Linux commands on the host:
    ```bash
    df -h . # Check space in the current directory (run in postgres-ha-setup/)
    du -sh data/ # Check space used by database data
    du -sh pgbackrest/repo/ # Check space used by backups
    ```
*   Ensure sufficient free space, especially for database growth and backup retention.

### 6. Routine Tasks

**6.1 Running Backups Manually**
While backups should ideally be automated (e.g., using host cron calling `docker-compose exec`), you can run them manually:
```bash
# Full Backup
docker-compose exec pgbackrest pgbackrest --stanza=main --type=full backup

# Incremental Backup
docker-compose exec pgbackrest pgbackrest --stanza=main --type=incr backup

# Differential Backup
docker-compose exec pgbackrest pgbackrest --stanza=main --type=diff backup
```

**6.2 Checking Logs**
Regularly review logs for errors or warnings:
```bash
# Check primary DB logs for errors
docker-compose logs db-primary | grep -i 'ERROR\|WARNING\|FATAL'

# Check replica logs
docker-compose logs db-replica | grep -i 'ERROR\|WARNING\|FATAL'

# Check pgbouncer logs
docker-compose logs pgbouncer | grep -i 'ERROR\|WARNING'

# Check pgbackrest logs (if running via cron or for background tasks)
# Look in ./pgbackrest/log/ on the host
```

**6.3 Managing Disk Space**
*   **Database:** Use `VACUUM` (especially `VACUUM FULL`, though it locks tables) or tools like `pg_repack` to reclaim space from bloated tables/indexes if necessary. Monitor table/index sizes via pgAdmin or SQL queries.
*   **Backups:** Adjust pgBackRest retention settings (`repo1-retention-full`, etc.) in `pgbackrest/conf/pgbackrest.conf` and expire old backups if needed:
    ```bash
    # Edit ./pgbackrest/conf/pgbackrest.conf to change retention
    # Expire backups according to the *new* retention settings
    docker-compose exec pgbackrest pgbackrest --stanza=main expire
    # Then restart the pgbackrest container if it runs background tasks (like archiving)
    docker-compose restart pgbackrest
    ```
*   **WAL Files:** PostgreSQL automatically manages WAL file cleanup based on replication needs and `archive_command` success (if configured). Ensure `max_wal_senders` and `wal_keep_size` (or replication slots) are adequate but not excessive. Check the `pg_wal` directory size on the primary if space issues arise.

### 7. Configuration Management

**Caution:** Always back up configuration files before editing. Test changes in a non-production environment first if possible.

**7.1 Modifying PostgreSQL Configuration (`postgresql.conf`, `pg_hba.conf`)**
1.  **Edit Files:** Modify the relevant files on the host system:
    *   `./config/primary/postgresql.conf` or `./config/primary/pg_hba.conf` for the primary.
    *   `./config/replica/postgresql.conf` or `./config/replica/pg_hba.conf` for the replica.
2.  **Apply Changes:**
    *   **`pg_hba.conf`:** Changes require a configuration reload.
        ```bash
        docker-compose exec db-primary psql -U $POSTGRES_USER -c "SELECT pg_reload_conf();"
        # Or for replica:
        docker-compose exec db-replica psql -U $POSTGRES_USER -c "SELECT pg_reload_conf();"
        ```
    *   **`postgresql.conf`:** Some parameters require only a reload (`pg_reload_conf()`), while others (e.g., `max_connections`, `shared_buffers`, `wal_level`) require a full **restart** of the PostgreSQL service. Check the PostgreSQL documentation for the specific parameter.
        ```bash
        # If restart is required:
        docker-compose restart db-primary
        docker-compose restart db-replica
        ```

**7.2 Modifying PgBouncer Configuration (`pgbouncer.ini`, `userlist.txt`)**
1.  **Edit Files:** Modify `./pgbouncer/pgbouncer.ini` or `./pgbouncer/userlist.txt` on the host system.
    *   Remember to update SCRAM hashes in `userlist.txt` if passwords change (see User Management).
2.  **Apply Changes:** PgBouncer needs to reload its configuration.
    *   Connect to the PgBouncer admin console (see 5.4):
        ```bash
        PGPASSWORD=$POSTGRES_PASSWORD psql -h localhost -p 6432 -U $POSTGRES_USER pgbouncer
        ```
    *   Inside the psql console, run:
        ```sql
        RELOAD;
        ```
    *   Alternatively, restart the container (causes brief connection interruption):
        ```bash
        docker-compose restart pgbouncer
        ```

### 8. Database User Management

**CRITICAL:** When using PgBouncer with password authentication (especially SCRAM), you must update credentials in **both** PostgreSQL **and** PgBouncer's `userlist.txt`.

**8.1 Adding a New User**
1.  **Create User in PostgreSQL:** Connect to `db-primary` and create the user:
    ```bash
    docker-compose exec db-primary psql -U $POSTGRES_USER -d $POSTGRES_DB
    # Inside psql:
    CREATE USER new_app_user WITH PASSWORD 'a_strong_password';
    GRANT CONNECT ON DATABASE $POSTGRES_DB TO new_app_user;
    -- Grant other necessary permissions (SELECT, INSERT, etc. on specific tables)
    GRANT SELECT ON TABLE my_table TO new_app_user;
    -- etc.
    \q
    ```
2.  **Get SCRAM Hash:** Retrieve the new user's SCRAM hash from `db-primary`:
    ```bash
    docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT rolpassword FROM pg_shadow WHERE usename = 'new_app_user';"
    ```
3.  **Update `userlist.txt`:** Edit `./pgbouncer/userlist.txt` on the host and add a line for the new user, pasting the SCRAM hash obtained above:
    ```
    "new_app_user" "SCRAM-SHA-256$..."
    ```
4.  **Reload PgBouncer:** Connect to the PgBouncer admin console or restart the service:
    ```bash
    docker-compose exec pgbouncer psql -U $POSTGRES_USER -p 6432 pgbouncer -c "RELOAD;"
    # Or: docker-compose restart pgbouncer
    ```

**8.2 Changing a User's Password**
1.  **Change Password in PostgreSQL:** Connect to `db-primary`:
    ```bash
    docker-compose exec db-primary psql -U $POSTGRES_USER -d $POSTGRES_DB
    # Inside psql:
    ALTER USER existing_user WITH PASSWORD 'new_strong_password';
    \q
    ```
2.  **Get New SCRAM Hash:** Retrieve the updated hash for `existing_user`.
    ```bash
    docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT rolpassword FROM pg_shadow WHERE usename = 'existing_user';"
    ```
3.  **Update `userlist.txt`:** Edit `./pgbouncer/userlist.txt` and replace the old hash for `existing_user` with the new one.
4.  **Reload PgBouncer:** `RELOAD;` via admin console or `docker-compose restart pgbouncer`.

**8.3 Removing a User**
1.  **Remove from `userlist.txt`:** Edit `./pgbouncer/userlist.txt` and delete the line for the user.
2.  **Reload PgBouncer:** `RELOAD;` via admin console or `docker-compose restart pgbouncer`.
3.  **Drop User in PostgreSQL:** Connect to `db-primary`. **Be careful:** Reassign ownership of objects owned by the user first, or use `DROP OWNED`.
    ```bash
    docker-compose exec db-primary psql -U $POSTGRES_USER -d $POSTGRES_DB
    # Inside psql:
    -- Optional, but safer: Revoke privileges and reassign owned objects
    -- REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM user_to_remove;
    -- REASSIGN OWNED BY user_to_remove TO $POSTGRES_USER;
    DROP USER user_to_remove;
    \q
    ```

### 9. Backup and Restore Operations

**9.1 Performing Backups**
Use `docker-compose exec pgbackrest ...` as shown in sections 5.5 and 6.1. Automate this using host `cron` or a similar scheduler.

**9.2 Restoring (Overview & Considerations)**
Restoring is a critical but complex operation. **Always test your restore process regularly.**

*   **Restoration Target:** You can restore to the primary location (overwriting existing data) or potentially to the replica's data directory (requires careful handling of replication settings). Restoring to a completely new instance/volume is often safest for testing.
*   **Process:** Generally involves:
    1.  Stopping the target PostgreSQL instance (`docker-compose stop db-primary`).
    2.  Cleaning the target PGDATA directory (`rm -rf ./data/primary/*`).
    3.  Running the `pgbackrest restore` command via `docker-compose exec`.
        ```bash
        # Example: Restore the latest backup to the primary's data location
        docker-compose exec pgbackrest pgbackrest --stanza=main --delta restore --pg1-path=/var/lib/postgresql/data/pgdata
        # '--delta' is optional but recommended for faster restores if destination exists
        # Point-in-Time Recovery (PITR) example:
        # docker-compose exec pgbackrest pgbackrest --stanza=main --delta restore --type=time "--target=YYYY-MM-DD HH:MM:SS" --target-action=promote
        ```    4.  Starting the restored PostgreSQL instance (`docker-compose start db-primary`).
    5.  Re-initializing any replicas if restoring the primary.
*   **Refer to pgBackRest Documentation:** The official [pgBackRest User Guide](https://pgbackrest.org/user-guide.html) provides comprehensive details on different restore scenarios (PITR, restoring specific backups, etc.).

### 10. Troubleshooting Common Issues

**10.1 Containers Not Starting**
*   **Check Logs:** `docker-compose logs <service_name>` is the first step. Look for specific error messages.
*   **Permissions:** Host volume permission issues are common. Ensure directories (`./data`, `./pgbackrest`, `./pgadmin-data`) are writable by the container user ID (see Setup guide).
*   **Configuration Errors:** Syntax errors in `.conf` or `.ini` files. Validate changes.
*   **Port Conflicts:** Ensure ports (5432, 6432, 8080) are not already in use on the host.
*   **Dependencies:** Ensure `db-primary` starts successfully before `db-replica` or `pgbouncer`. Check `depends_on` conditions in `docker-compose.yaml`.

**10.2 Replication Lag / Replica Not Syncing**
*   **Check Primary Load:** Is the primary under extremely heavy write load?
*   **Check Network:** Are containers on the same Docker network? Any network latency issues between primary and replica (less common in single-host Docker Compose)?
*   **Check Replica Resources:** Does the replica container have sufficient CPU/RAM? Check `docker stats`.
*   **Check Logs:** Look for errors on both primary (`max_wal_senders` reached?) and replica (connection issues, WAL application errors).
*   **Check Replication Query:** Use `SELECT * FROM pg_stat_replication;` on the primary (see 5.3).
*   **Replication Slots:** If using slots, ensure the slot exists and is active (`SELECT * FROM pg_replication_slots;` on primary). If not using slots, ensure `wal_keep_size` on the primary is large enough to retain WAL files needed by the replica.

**10.3 Cannot Connect via PgBouncer (Port 6432)**
*   **Is PgBouncer Running?** `docker-compose ps`
*   **Check PgBouncer Logs:** `docker-compose logs pgbouncer`. Look for "no such user", password authentication failures, or pool errors.
*   **Check `userlist.txt`:** Does the user exist? Is the SCRAM hash correct and up-to-date?
*   **Check `pgbouncer.ini`:** Is the `listen_addr`, `listen_port` correct? Is `auth_type` set correctly (`scram-sha-256`)? Is the database connection string in `[databases]` correct (pointing to `db-primary`)?
*   **Check Primary DB:** Is `db-primary` running and accepting connections? Can PgBouncer connect to it? (Check PgBouncer logs).
*   **Firewall:** Is port 6432 blocked on the host firewall (if connecting from outside the host)?

**10.4 Cannot Connect via pgAdmin (Port 8080)**
*   **Is pgAdmin Running?** `docker-compose ps`
*   **Check pgAdmin Logs:** `docker-compose logs pgadmin`.
*   **Check URL/Port:** Are you accessing `http://<host_ip>:8080`?
*   **Browser Issues:** Clear cache/cookies or try a different browser.
*   **Server Connection Issues (within pgAdmin):** If pgAdmin loads but can't connect to a *database*, troubleshoot that connection as you would any other (check hostname (`pgbouncer`, `db-primary`), port (6432, 5432), credentials, `pg_hba.conf` on the target database).

**10.5 Backup Failures**
*   **Check pgBackRest Logs:** `docker-compose logs pgbackrest` (if run via cron) or console output if run manually. Also check `./pgbackrest/log/` on the host.
*   **Check Configuration:** `docker-compose exec pgbackrest pgbackrest --stanza=main check`. This validates connectivity and paths.
*   **Permissions:** Ensure the `postgres` user inside the `db-primary` container can write to necessary directories if `archive_command` is used. Ensure the `pgbackrest` container has access to the repository (`./pgbackrest/repo/`).
*   **Connectivity:** Can the `pgbackrest` container reach `db-primary` on port 5432?
*   **Disk Space:** Is there enough space in the backup repository (`./pgbackrest/repo/`)?

### 11. Updates and Maintenance

*   **PostgreSQL Minor Version Updates:** Usually safe. Update the image tag in `docker-compose.yaml` (e.g., `postgres:15.3` to `postgres:15.4`) for both `db-primary` and `db-replica`, then `docker-compose pull` and `docker-compose up -d`. Downtime occurs during restart. Always back up first.
*   **PostgreSQL Major Version Upgrades (e.g., 15 to 16):** Complex. Requires using `pg_upgrade` or logical replication methods. This typically involves significant planning and downtime and is beyond the scope of simple Docker Compose administration. Refer to official PostgreSQL upgrade documentation.
*   **Component Updates (pgAdmin, PgBouncer, pgBackRest):** Update image tags, pull, and restart (`docker-compose pull && docker-compose up -d`). Check release notes for breaking changes.
*   **Docker Engine/Compose Updates:** Follow official Docker documentation. Usually non-disruptive to running containers unless the daemon itself is restarted.

### 12. Security Considerations

*   **`.env` File:** Protect this file strictly. It contains all secrets. Do not commit it to version control.
*   **Passwords:** Use strong, unique passwords for all accounts.
*   **`pg_hba.conf`:** Restrict access as much as possible. Use specific IP addresses or Docker network ranges instead of `all` where feasible. Use `scram-sha-256` authentication.
*   **Network Exposure:** Only expose ports to the host (`ports:` section in `docker-compose.yaml`) if necessary. Prefer connecting via Docker's internal network using service names. If host ports are exposed, consider binding to `127.0.0.1:` instead of `0.0.0.0:` (default) to limit access to the local machine. Use host firewalls.
*   **pgAdmin Security:** The default setup runs pgAdmin over HTTP. For production or sensitive environments, configure pgAdmin behind a reverse proxy (like Nginx or Traefik) providing HTTPS.
*   **Backup Encryption:** Consider enabling pgBackRest repository encryption (`repo1-cipher-type`, `repo1-cipher-pass` in `pgbackrest.conf` / `.env`) for backups at rest. Secure the passphrase.

---