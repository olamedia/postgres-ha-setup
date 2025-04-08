Okay, here is a manual covering local installation and a chapter on scaling out the Docker Compose setup you defined.

---

## Manual: PostgreSQL HA Setup with Docker Compose

This manual guides you through setting up a local PostgreSQL environment using Docker Compose, featuring:

*   A Primary PostgreSQL server
*   A Streaming Replica for availability and read scaling
*   PgBouncer for connection pooling
*   pgAdmin4 for web-based administration
*   pgBackRest for backups
*   Host-mounted volumes for persistent data

**Target Audience:** Developers or Ops personnel needing a local, resilient PostgreSQL setup that mimics aspects of a production environment.

**Source Files:** This manual assumes you have the `docker-compose.yaml`, `.env`, and configuration files (`postgresql.conf`, `pg_hba.conf`, `entrypoint-replica.sh`, `pgbouncer.ini`, `userlist.txt`, `pgbackrest.conf`) as defined in the previous example.

---

### Chapter 1: Local Installation and Setup

This chapter covers getting the environment running on your local machine.

**1.1 Prerequisites**

*   **Docker:** Install Docker Desktop (Windows/macOS) or Docker Engine (Linux). See [official Docker documentation](https://docs.docker.com/get-docker/).
*   **Docker Compose:** Usually included with Docker Desktop. For Linux, you might need to install it separately. See [official Docker Compose documentation](https://docs.docker.com/compose/install/).
*   **Git (Optional):** If you're cloning a repository containing these files.
*   **Text Editor:** For creating/editing configuration files.
*   **Terminal/Command Prompt:** To run Docker commands.
*   **Operating System:** Linux is assumed for file paths and permissions examples. Adjustments may be needed for macOS or Windows (especially regarding volume paths and permissions).

**1.2 Prepare Project Files**

1.  **Create Project Directory:**
    ```bash
    mkdir postgres-ha-setup
    cd postgres-ha-setup
    ```
2.  **Create Subdirectories:**
    ```bash
    mkdir -p data/primary data/replica config/primary config/replica pgbouncer pgbackrest/conf pgbackrest/log pgbackrest/repo pgadmin-data
    ```
3.  **Create Configuration Files:** Place the following files in their respective directories with the content provided previously:
    *   `docker-compose.yaml` (in `postgres-ha-setup/`)
    *   `.env` (in `postgres-ha-setup/` - **IMPORTANT: Secure this!**)
    *   `config/primary/postgresql.conf`
    *   `config/primary/pg_hba.conf`
    *   `config/replica/postgresql.conf`
    *   `config/replica/pg_hba.conf`
    *   `config/replica/entrypoint-replica.sh`
    *   `pgbouncer/pgbouncer.ini`
    *   `pgbouncer/userlist.txt` (Initially empty or with placeholder)
    *   `pgbackrest/conf/pgbackrest.conf`
4.  **Set Replica Entrypoint Permissions:** Make the replica script executable:
    ```bash
    chmod +x config/replica/entrypoint-replica.sh
    ```
5.  **Populate `.env` File:** Open the `.env` file and set strong, unique passwords for:
    *   `POSTGRES_PASSWORD`
    *   `REPLICATION_PASSWORD`
    *   `PGADMIN_DEFAULT_PASSWORD`
    *   Optionally set `PGBACKREST_REPO1_CIPHER_PASS` for encrypted backups.

**1.3 Handle Host Volume Permissions (Potential Pitfall)**

Docker containers run processes as specific users (e.g., `postgres`, often UID `999` or `70`). When using host-mounted volumes, the directories on your *host machine* need to be writable by that *container user's ID*.

*   **Find the UID:** You might need to check the specific `postgres` image documentation or inspect a running container. Common IDs are `999` (Debian-based images) or `70` (Alpine-based).
*   **Set Permissions:** You may need to change the ownership of the host directories. **Be careful with `sudo`**.
    ```bash
    # Example assuming UID 999 (Check your image!)
    sudo chown -R 999:999 data/ pgbackrest/ pgadmin-data/
    # Or grant broader write permissions (less secure, okay for local dev)
    # sudo chmod -R 777 data/ pgbackrest/ pgadmin-data/
    ```
*   **Alternative (Easier Permissions):** If permissions are problematic, modify `docker-compose.yaml` to use Docker *named volumes* instead of host mounts for `data`, `pgbackrest`, and `pgadmin-data`. Docker manages permissions automatically for named volumes.

**1.4 Start the Services**

1.  Navigate to the `postgres-ha-setup` directory in your terminal.
2.  Run Docker Compose in detached mode:
    ```bash
    docker-compose up -d
    ```
3.  Docker will pull the necessary images and start the containers. This might take a few minutes the first time.
4.  **Monitor Startup:** Check the logs to ensure containers start correctly, especially the primary and replica DBs.
    ```bash
    docker-compose logs -f # Press Ctrl+C to stop following
    # Or check specific services
    docker-compose logs db-primary
    docker-compose logs db-replica
    ```
    Look for messages indicating the primary database is ready and the replica is connecting and syncing.

**1.5 Post-Start Initialization (CRITICAL)**

Several steps must be performed *after* the containers are running:

1.  **Create Replication User on Primary:**
    *   Connect to the primary database. You can use pgAdmin (see step 1.6) or `docker exec`:
        ```bash
        docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
        CREATE USER ${REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
        -- Optional: Create Replication Slot (Recommended for reliability)
        -- SELECT pg_create_physical_replication_slot('replica_slot');
        -- Note: If using slots, configure primary_slot_name in replica's recovery settings (entrypoint script/postgresql.conf).
        EOF
        ```
2.  **Create PgBouncer Authentication User on Primary:**
    *   PgBouncer needs its own user to query `pg_shadow` for SCRAM authentication.
    *   Connect to the primary database:
        ```bash
        # Use a strong, unique password here, it's only for pgbouncer's internal use
        PGBOUNCER_INTERNAL_PASS='a_secure_internal_password'

        docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
        CREATE USER pgbouncer_auth WITH PASSWORD '${PGBOUNCER_INTERNAL_PASS}';
        GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO pgbouncer_auth;
        -- Grant permission to read password hashes (required for SCRAM auth_query)
        GRANT pg_read_all_settings TO pgbouncer_auth; -- PG10+ required for pg_shadow access via query
        ALTER USER pgbouncer_auth SET synchronous_commit = 'local'; -- Recommended for pgbouncer performance
        EOF
        ```
    *   Update `pgbouncer/pgbouncer.ini`'s `auth_user` to `pgbouncer_auth`.
    *   Update the `PGBOUNCER_AUTH_USER_PASSWORD` environment variable in `docker-compose.yaml` under the `pgbouncer` service if the Bitnami image requires it for its startup scripts (check their documentation).

3.  **Generate SCRAM Hash for `userlist.txt`:**
    *   Get the SCRAM hash for the main application user (`myuser`):
        ```bash
        docker-compose exec -T db-primary psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT rolpassword FROM pg_shadow WHERE usename = '${POSTGRES_USER}';"
        ```
    *   **Copy the entire output** (e.g., `SCRAM-SHA-256$...`).
    *   Edit `pgbouncer/userlist.txt` and add the entry:
        ```
        "myuser" "SCRAM-SHA-256$4096$...REST_OF_THE_HASH..."
        ```
        *(Replace the hash with the actual output you copied)*
    *   Add lines for any other database users that need to connect via PgBouncer.
    *   **Restart PgBouncer** to apply the changes:
        ```bash
        docker-compose restart pgbouncer
        ```

4.  **Initialize pgBackRest Stanza:**
    *   Tell pgBackRest about your primary database cluster (stanza):
        ```bash
        docker-compose exec db-primary pgbackrest --stanza=main --log-level-console=info stanza-create
        ```
    *   Verify the setup from the pgBackRest container:
        ```bash
        docker-compose exec pgbackrest pgbackrest --stanza=main --log-level-console=info check
        ```
        This command should complete successfully, confirming connectivity and configuration. Troubleshoot paths and permissions in `pgbackrest.conf` if it fails.

**1.6 Verify the Setup**

1.  **Check Container Status:**
    ```bash
    docker-compose ps
    ```
    All services should show `Up` or `running`.
2.  **Access pgAdmin:**
    *   Open `http://localhost:8080` in your browser.
    *   Log in with the email/password from your `.env` file (`PGADMIN_DEFAULT_EMAIL`, `PGADMIN_DEFAULT_PASSWORD`).
    *   **Add Servers:**
        *   Click "Add New Server".
        *   **General Tab:** Give it a name (e.g., "Primary (via Pgbouncer)").
        *   **Connection Tab:**
            *   Host name/address: `pgbouncer` (use the service name)
            *   Port: `6432`
            *   Maintenance database: `mydatabase` (or your `POSTGRES_DB`)
            *   Username: `myuser` (or your `POSTGRES_USER`)
            *   Password: The `POSTGRES_PASSWORD` from your `.env` file.
            *   Save password: Yes.
        *   Click "Save".
        *   You can optionally add direct connections to `db-primary` (port 5432) and `db-replica` (port 5432) for administrative tasks or observing replication, but applications should use PgBouncer.
3.  **Check Replication:**
    *   Connect to the *primary* database (using pgAdmin direct connection or `docker exec db-primary psql ...`).
    *   Run: `SELECT * FROM pg_stat_replication;`
    *   You should see an entry for the replica (`db-replica`), with state `streaming`.
    *   Connect to the *replica* database. It should be in recovery mode and allow read-only queries. Try `SELECT 1;`. Create/Insert/Update queries should fail.
4.  **Test PgBouncer Connection:**
    *   Use `psql` from your host (if installed) or another container:
        ```bash
        # From host machine (if psql client installed)
        PGPASSWORD=$POSTGRES_PASSWORD psql -h localhost -p 6432 -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 'Connected via PgBouncer successfully!' AS msg;"

        # Or from within another container on the db-network
        # docker run --rm -it --network postgres-ha-setup_db-network postgres:15 psql -h pgbouncer -p 6432 -U $POSTGRES_USER -d $POSTGRES_DB
        ```

**1.7 Using the Environment**

*   **Application Connection:** Configure your applications to connect to PostgreSQL using Host: `localhost` (or `pgbouncer` if connecting from another container in the same Docker network), Port: `6432`, and the database credentials from the `.env` file.
*   **Administration:** Use pgAdmin (`http://localhost:8080`) or `docker exec ... psql ...` for administrative tasks. Connect directly to `db-primary` (port 5432) for writes/admin, and optionally to `db-replica` (port 5432) to verify reads.
*   **Backups:** Perform backups using the `pgbackrest` container:
    ```bash
    # Full Backup
    docker-compose exec pgbackrest pgbackrest --stanza=main --type=full backup

    # Incremental Backup (requires a previous full backup)
    docker-compose exec pgbackrest pgbackrest --stanza=main --type=incr backup

    # Differential Backup
    docker-compose exec pgbackrest --stanza=main --type=diff backup

    # View backup info
    docker-compose exec pgbackrest pgbackrest --stanza=main info
    ```
    Backups will be stored in the `./pgbackrest/repo` directory on your host.
*   **Restore:** Restoring requires stopping the target database and running pgBackRest restore commands. Consult the [pgBackRest documentation](https://pgbackrest.org/user-guide.html) for detailed procedures.

**1.8 Stopping the Environment**

1.  To stop the containers without deleting data:
    ```bash
    docker-compose stop
    ```
2.  To stop and remove the containers:
    ```bash
    docker-compose down
    ```
3.  To stop, remove containers, AND remove the named networks (but **not** the host-mounted data volumes):
    ```bash
    docker-compose down --remove-orphans
    ```
4.  **To remove the persisted data:** Manually delete the `data/`, `pgadmin-data/`, and `pgbackrest/repo` directories on your host machine. **Use caution!**

---

### Chapter 2: Scaling Considerations

The `docker-compose` setup provides the core *components* for a scalable PostgreSQL architecture, but `docker-compose` itself is designed for single-host development and testing, not large-scale production deployment across hundreds of servers.

**2.1 Limitations of Docker Compose for Scale**

*   **Single Host:** `docker-compose` orchestrates containers on the machine where it's run. It doesn't manage deployments across multiple hosts.
*   **Networking:** Relies on Docker's bridge networking, which is host-local. Cross-host communication requires overlays or different network drivers, usually managed by an orchestrator.
*   **Service Discovery:** Containers find each other using service names within the Docker Compose network, which doesn't extend across hosts.
*   **Scheduling & Resource Management:** No intelligent placement of containers based on resource availability across a cluster of machines.
*   **Health Checks & Self-Healing:** Basic container health checks exist, but automated failover/replacement across hosts is missing.
*   **Storage:** Host volumes tie data to a specific machine, hindering container rescheduling and failover.

**2.2 Transitioning to a Scaled Architecture (Key Concepts & Tools)**

To scale this setup to tens or hundreds of servers, you need a **Container Orchestrator** like **Kubernetes** (most common) or HashiCorp Nomad. Here's how the components translate:

1.  **PostgreSQL High Availability (Patroni):**
    *   **Problem:** The current replica is a warm standby. Failover requires manual intervention.
    *   **Solution:** Use **Patroni**. Patroni manages PostgreSQL clusters, automating leader election (primary selection) and failover using a Distributed Consensus Store (DCS) like **etcd**, **Consul**, or **ZooKeeper**.
    *   **How:** You'd run PostgreSQL and Patroni together in containers (often using a pre-built Patroni image). Patroni instances communicate via the DCS to maintain cluster state and manage failover. Kubernetes StatefulSets are typically used to manage Patroni/Postgres pods.

2.  **Connection Pooling (PgBouncer):**
    *   **Importance:** Still crucial, perhaps even more so with many application instances.
    *   **Deployment:** PgBouncer can be deployed:
        *   As a *sidecar* container alongside each application pod (minimizes network hops).
        *   As a separate, scalable service/deployment within the orchestrator, fronted by its own load balancer.
    *   **Configuration:** Configuration (like `userlist.txt`) needs to be managed centrally (e.g., Kubernetes ConfigMaps/Secrets) and potentially updated dynamically if database users change frequently.

3.  **Load Balancing & Service Discovery:**
    *   **Problem:** How do applications find the *current* primary DB or the pool of read replicas/PgBouncers?
    *   **Solution:** Orchestrator's built-in service discovery and load balancing.
        *   **Kubernetes:** Services (e.g., `ClusterIP`, `LoadBalancer`) provide stable endpoints. Patroni typically updates a Kubernetes Service endpoint (`primary-service`) to point to the *current* primary pod after a failover. A separate service (`replica-service`) can load-balance across read replicas.
        *   **External Load Balancers:** Tools like **HAProxy** can be configured (often dynamically via Patroni callbacks or health checks) to route traffic appropriately (write traffic to primary, read traffic to replicas or PgBouncer).

4.  **Persistent Storage:**
    *   **Problem:** Host volumes are not suitable for clustered environments.
    *   **Solution:** Network-attached, distributed storage solutions managed by the orchestrator.
        *   **Kubernetes:** Persistent Volumes (PVs) and Persistent Volume Claims (PVCs) abstract underlying storage (NFS, Ceph, Cloud Provider block storage like EBS/GCE Persistent Disk/Azure Disk). StatefulSets manage persistent identity and storage for stateful applications like databases.
        *   pgBackRest backups should also target persistent, ideally off-site or object storage (NFS, S3-compatible).

5.  **Backup & Restore (pgBackRest):**
    *   **Scalability:** pgBackRest itself scales well.
    *   **Deployment:** Run pgBackRest backup commands as scheduled jobs within the orchestrator (e.g., Kubernetes CronJobs).
    *   **Repository:** The backup repository (`repo1-path`) must be on shared, persistent storage accessible by the pgBackRest job runners and potentially by database pods during restore operations (e.g., NFS mount, S3 via FUSE or native support).

6.  **Configuration Management:**
    *   **Problem:** Managing configuration files (`postgresql.conf`, `.env`) across many instances.
    *   **Solution:** Orchestrator features and external tools.
        *   **Kubernetes:** ConfigMaps for non-sensitive data, Secrets for sensitive data (like `.env` content). Templating tools like **Helm** are commonly used to package and manage application deployments and their configurations on Kubernetes.
        *   **Infrastructure as Code:** Tools like Terraform, Ansible, Chef, Puppet can manage the underlying infrastructure and deploy/configure applications and the orchestrator itself.

7.  **Monitoring and Logging:**
    *   **Essential:** At scale, you need robust monitoring (Prometheus, Grafana with PostgreSQL exporters) and centralized logging (EFK stack - Elasticsearch, Fluentd, Kibana; or PLG stack - Promtail, Loki, Grafana).

**2.3 Summary of Scaling**

The Docker Compose file defines the *application pattern* (Primary DB, Replica DB, Pooler, Admin UI, Backup). Scaling involves taking this pattern and deploying/managing it using an orchestrator (like Kubernetes) which handles the distributed systems challenges: service discovery, load balancing, automated failover (with Patroni), persistent network storage, configuration management, and scheduling across a cluster of servers.

---
