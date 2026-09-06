# Entrypoint documentation (`docker/entrypoint.sh`)

The entrypoint script manages the full lifecycle of a PostgreSQL + repmgr node: config rendering → initialization/cloning → startup → repmgr registration → process supervision.

---

## 1. Execution flow

```
 ┌─────────────────────────────────────────────────────────────────┐
 │ 1. Environment validation                                       │
 │    • required variables (POSTGRES_*, REPMGR_*, ...)             │
 │    • role ∈ {primary, standby}                                  │
 │    • REPMGR_PRIMARY_HOST required for standby                   │
 │    • REPMGR_NODE_ID must be a positive integer                  │
 ├─────────────────────────────────────────────────────────────────┤
 │ 2. Config rendering                                             │
 │    • repmgr.conf: envsubst over config/repmgr.conf              │
 │    • upstream_node_id removed for primary                       │
 │    • symlink /etc/repmgr.conf → repmgr.conf                     │
 │    • .pgpass (chmod 600, owned by postgres) for both DB users   │
 ├─────────────────────────────────────────────────────────────────┤
 │ 3. Cluster initialization (only if PGDATA is empty)             │
 │    PRIMARY: initdb (scram-sha-256, checksums) → postgresql.conf │
 │             → pg_hba → temporary start → create repmgr user     │
 │             and database → extension → primary register         │
 │             → stop temporary instance                           │
 │    STANDBY: wait for primary → standby clone (pg_basebackup)    │
 │             → primary_conninfo (no password; passfile=.pgpass)  │
 ├─────────────────────────────────────────────────────────────────┤
 │ 4. Consistency check of existing PGDATA                         │
 │    • standby without standby.signal → error (interrupted clone) │
 │    • standby PGDATA with primary role → refuse to start         │
 │    • with FORCE_REINIT=true → wipe PGDATA and re-initialize     │
 ├─────────────────────────────────────────────────────────────────┤
 │ 5. Start PostgreSQL (gosu postgres, background)                 │
 │ 6. Register node in repmgr.nodes (retry for standby)            │
 │ 7. Start repmgrd (daemonized, pid file in /var/run/repmgr/)     │
 │ 8. Supervision loop (every 30 s):                               │
 │    • PostgreSQL died → exit 1 (container restarts)              │
 │    • repmgrd died → automatic restart                           │
 │    • SIGTERM/SIGINT → graceful shutdown, exit 0                 │
 └─────────────────────────────────────────────────────────────────┘
```

Key principles:

- **Privileges**: the container starts as root, but every data-touching command runs through `gosu postgres ...` (the same pattern as the official postgres image). This is also required for `psql` peer authentication (OS user = DB user).
- **Secrets**: passwords are never written into PostgreSQL config files in plain text — client tools (`repmgr`, `psql`) read them from `/var/lib/postgresql/.pgpass` (chmod 600, owned by `postgres`).
- **Idempotency**: on restart with existing `PGDATA`, init/clone is skipped; only a state-consistency check is performed and `pg_hba.conf` is re-rendered.

---

## 2. Environment variables

### Required (missing = immediate exit 1 with a message)

| Variable | Example | Description |
|---|---|---|
| `POSTGRES_USER` | `postgres` | PostgreSQL superuser |
| `POSTGRES_PASSWORD` | `...` | its password |
| `POSTGRES_DB` | `appdb` | main database (also holds repmgr metadata) |
| `REPMGR_USER` | `repmgr` | replication/metadata user |
| `REPMGR_PASSWORD` | `...` | its password |
| `REPMGR_NODE_NAME` | `pg-node-1` | unique node name in the cluster |
| `REPMGR_NODE_ID` | `1` | unique numeric node ID (integer > 0) |
| `REPMGR_NODE_ROLE` | `primary` | `primary` or `standby` |
| `NODE_DOMAIN` | `pg-node-1` | node hostname used in conninfo |

### Optional (with defaults)

| Variable | Default | Description |
|---|---|---|
| `REPMGR_PRIMARY_HOST` | `localhost` | primary hostname (**required** for standby — validated) |
| `REPMGR_UPSTREAM_NODE_ID` | *(empty)* | upstream node ID for standby (cascaded replication); removed from config for primary |
| `REPMGR_PRIORITY` | `100` | failover priority |
| `POSTGRES_PORT` | `5432` | port |
| `PGDATA` | `/var/lib/postgresql/data` | data directory |
| `PG_HBA_SOURCE` / `PG_HBA_TARGET` | `/etc/pg_hba.conf.template` / `$PGDATA/pg_hba.conf` | pg_hba template and target |
| `REPMGR_CONF_TEMPLATE` / `REPMGR_CONF` | `/var/lib/postgresql/repmgr.conf.template` / `.../repmgr.conf` | repmgr config template and target |
| `REPMGR_LOG_FILE` | `/var/log/repmgr/repmgr.log` | repmgr/repmgrd log file |
| `DOCKER_SUBNET` | `172.16.0.0/12` | subnet allowed by pg_hba |
| `LISTEN_ADDRESSES` | `*` | PostgreSQL listen_addresses |
| `MAX_WAL_SENDERS` / `MAX_REPLICATION_SLOTS` | `10` / `10` | replication limits |
| `WAL_LEVEL` | `replica` | wal_level |
| `WAL_KEEP_SIZE` | `1GB` | wal_keep_size |
| `FORCE_REINIT` | `false` | `true` = wipe PGDATA and re-initialize when the role conflicts with the data (destructive, manual) |

---

## 3. What each mode does

### Primary (first run)

1. `initdb` with `scram-sha-256`, data checksums, password from pwfile.
2. Appends to `postgresql.conf`: `wal_level`, `max_wal_senders`, `max_replication_slots`, `hot_standby`, `wal_keep_size`, `password_encryption`, `shared_preload_libraries=repmgr`, `archive_mode=off`.
3. Renders `pg_hba.conf` from the template (envsubst).
4. Temporarily starts PostgreSQL on `127.0.0.1` only, creates the `REPMGR_USER` user (SUPERUSER LOGIN, scram), the `POSTGRES_DB` database, the `repmgr` extension, and registers the primary (`repmgr primary register --force`).
5. Stops the temporary instance and continues with the common startup path.

### Standby (first run)

1. Waits for `REPMGR_PRIMARY_HOST` to accept connections (up to 120 attempts x 2 s ≈ 4 minutes).
2. Runs `repmgr standby clone --force` (pg_basebackup from the primary; password from `.pgpass`).
3. Writes `primary_conninfo` to `postgresql.auto.conf` — **without a password**, with a `passfile` pointing at `.pgpass`, so the password never appears in config files or `SHOW ALL` output.

### Subsequent restarts (either role)

- If `PGDATA` exists, init/clone is skipped.
- The data state is checked against the role (via `standby.signal`): a mismatch refuses to start with a clear message (protects against losing a replica or silently broken nodes). With `FORCE_REINIT=true` the conflicting PGDATA is wiped and the node re-initializes.
- `pg_hba.conf` is re-rendered from the template so rules are always up to date.

---

## 4. Error handling

| Situation | Behavior |
|---|---|
| Required variable missing | `ERROR: <VAR> is required`, exit 1 |
| Invalid role / non-numeric NODE_ID | message with the received value, exit 1 |
| `REPMGR_PRIMARY_HOST` missing for standby | message, exit 1 (before any disk changes) |
| repmgr.conf template missing | message, exit 1 |
| Primary unreachable (standby) | wait up to 4 minutes; on timeout exit 1 → `restart: unless-stopped` restarts the container |
| `standby clone` fails (e.g. network drop) | exit 1 via `set -e`; next start detects PGDATA without `standby.signal` and demands `FORCE_REINIT` |
| repmgr extension missing | created automatically at startup |
| Node not registered in `repmgr.nodes` | automatic registration; standby retries up to 3 times with a 10 s pause |
| repmgrd dies at runtime | automatic restart of repmgrd, warning in the log |
| PostgreSQL dies at runtime | exit 1 → container restart |
| SIGTERM/SIGINT (docker stop) | graceful: TERM → PostgreSQL, wait for exit, TERM → repmgrd, exit 0 |
| Any command error | `set -Eeuo pipefail` + ERR trap prints `ERROR at line N` to stderr |

Guiding principles:

- **Fail fast**: all configuration checks run before any writes to disk.
- **No silent degradation**: failed clone/registration/startup means a visible container crash (via healthcheck + restart policy), not a "running but not replicating" node.

---

## 5. Running

### Single primary node

```bash
cp .env.example .env          # fill in the passwords
docker compose up -d --build
docker compose logs -f postgres
```

Expected final log line:

```
=== PostgreSQL node pg-node-1 (primary) is ready ===
```

### 3-node cluster

Run one copy of the project per node (or a compose override), each with its own `.env`:

| | node 1 | node 2 | node 3 |
|---|---|---|---|
| `REPMGR_NODE_ROLE` | `primary` | `standby` | `standby` |
| `REPMGR_NODE_ID` | `1` | `2` | `3` |
| `REPMGR_NODE_NAME` / `NODE_DOMAIN` / `CONTAINER_NAME` | `pg-node-1` | `pg-node-2` | `pg-node-3` |
| `REPMGR_PRIMARY_HOST` | *(n/a)* | `pg-node-1` | `pg-node-1` |
| `REPMGR_UPSTREAM_NODE_ID` | *(empty)* | `1` | `1` |
| `NODE_IP` | `172.28.0.10` | `172.28.0.11` | `172.28.0.12` |

All nodes must share one Docker network (`postgres-network`) and resolve each other by hostname (`NODE_DOMAIN`).

### Re-initializing a node

```bash
# CAUTION: destroys node data
docker compose down
docker volume rm <project>_postgres_data
```

`FORCE_REINIT` is deliberately not automatic: changing a role or re-cloning over existing data must always be a conscious decision. In a conflicting state the entrypoint suggests this variable in its error message.

---

## 6. Diagnostics and operations

```bash
# Cluster status (from any node)
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf cluster show

# Node and replication status
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf node status
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf node check

# repmgrd daemon
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf daemon status

# Logs
docker compose logs -f postgres                                  # entrypoint stdout + PostgreSQL
docker compose exec postgres tail -f /var/log/repmgr/repmgr.log  # repmgrd log
```

Container healthcheck: `pg_isready` every 15 s (start_period 60 s) — Docker reports `healthy/unhealthy` on its own.

---

## 7. Limitations and known trade-offs

- `POSTGRES_DB` serves both as the main database and the repmgr metadata database; for production workloads consider a separate database for repmgr.
- Automatic failover works via `repmgrd` (`failover automatic`), but client rerouting to the new primary is out of scope (add pgbouncer/HAProxy or a VIP manager in front).
- WAL archiving is disabled (`archive_mode=off`); for stricter durability configure a synchronous standby (`synchronous_standby_names`) or attach pgBackRest/wal-g.
- `standby clone` requires an already-initialized primary; node start order does not matter — a standby waits for the primary for up to 4 minutes.

---

## 8. Building the image (`docker/Dockerfile`)

The base is the official `postgres:17-bookworm` image. Added on top:

- **repmgr** from the PGDG apt repository (apt.postgresql.org) — this repository is already configured in the official postgres image, so no extra keys/sources are needed (per the official repmgr documentation, Debian/Ubuntu section). The version is pinned via a build arg.
- **gettext-base** — provides `envsubst`, used by the entrypoint to render configs.
- `/var/log/repmgr`, `/var/lib/postgresql`, `/var/run/repmgr` directories owned by postgres.
- `config/repmgr.conf` → `/var/lib/postgresql/repmgr.conf.template`, `docker/entrypoint.sh` → `/usr/local/bin/entrypoint.sh`.

`gosu` is already part of the official postgres image; `sudo` is deliberately not installed.

### Build args (overridable in docker-compose.yml or via `--build-arg`)

| Arg | Default | Description |
|---|---|---|
| `POSTGRES_VERSION` | `17` | base image tag (`postgres:<ver>-bookworm`) |
| `PG_MAJOR` | `17` | major version for the package name `postgresql-<major>-repmgr` |
| `REPMGR_VERSION` | `5.5.0` | pinned repmgr version |

To change PostgreSQL/repmgr versions: update the build args in `docker-compose.yml` and rebuild (`docker compose build --no-cache`).

### docker-compose.yml

| Setting | Value | Rationale |
|---|---|---|
| `expose: 5432` | no `ports` | port is not published to the host; cluster access only via the `postgres-network` |
| `ipv4_address` / `ipam.subnet` | from `.env` (`NODE_IP`/`DOCKER_SUBNET`) | static node addresses — required by pg_hba and for node-to-node visibility |
| `shm_size: 256mb` | — | PostgreSQL makes heavy use of shared memory; the 64 MB default is too small |
| `init: true` | — | tini as PID 1: proper signals, no zombies |
| `healthcheck` | `pg_isready` | Docker reports healthy/unhealthy independently of logs |
| `restart: unless-stopped` | — | automatic restart after a crash (entrypoint exit 1) |
| `postgres_data` volume | → `/var/lib/postgresql/data` | data survives container recreation |

---

## 9. Troubleshooting / FAQ

**Container restart loop, log shows `ERROR: REPMGR_PRIMARY_HOST is required...`**
A standby was started without the primary address. Set `REPMGR_PRIMARY_HOST` in the node's `.env`.

**`PGDATA exists but is not a standby (standby.signal missing)`**
The previous `standby clone` was interrupted midway. Stop the container, remove the volume (`docker compose down && docker volume rm <project>_postgres_data`) and start again — cloning will run from scratch.

**`PGDATA is a standby, but REPMGR_NODE_ROLE=primary`**
The node's role in `.env` does not match the data. Either fix the role, or consciously re-initialize (see above). The entrypoint never silently destroys existing data.

**`PostgreSQL on pg-node-1 not ready after 120 attempts`**
The standby cannot reach the primary within ~4 minutes. Check: shared Docker network (`docker network inspect`), `REPMGR_PRIMARY_HOST` hostname = primary's `CONTAINER_NAME`/`NODE_DOMAIN`, no subnet conflicts with other Docker networks.

**repmgr authentication error (`no pg_hba.conf entry ... host ... 172.x.x.x`)**
The node address is not covered by `DOCKER_SUBNET`. Make sure `DOCKER_SUBNET` in `.env` matches the `ipam.subnet` in compose, and that pg_hba was re-rendered (after changing the config, restart the container).

**repmgrd does not start / dies immediately**
Check `/var/log/repmgr/repmgr.log` inside the container. Common causes: invalid repmgr.conf parameter, node not registered, no connection to the primary.

**Password changed in `.env` but replication is broken**
The password lives in two places: in the database (`ALTER USER ... PASSWORD`) and in `.pgpass`. Update both: `ALTER USER repmgr WITH PASSWORD '...'` on the primary + restart the container (the entrypoint re-renders `.pgpass`).

**Need temporary access from the host**
Add `ports: ["127.0.0.1:5432:5432"]` in compose — bound to localhost so the port is not exposed externally. For other subnets, extend `DOCKER_SUBNET` or add rules to `config/pg_hba.conf`.
