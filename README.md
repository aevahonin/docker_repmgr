# Dockerized PostgreSQL with repmgr

Docker setup for a PostgreSQL cluster managed by [repmgr](https://repmgr.org/) — primary/standby replication with automatic failover.

> **Note:** documentation and code comments in this repository are in English; the original working notes were in Russian.

## Features

- **PostgreSQL 17 + repmgr 5.5** (pinned versions, built on the official `postgres` image).
- **Automatic failover** via `repmgrd` (`failover automatic`), replication slots enabled.
- **Hardened by default**: `scram-sha-256` authentication only, `pg_hba.conf` restricted to the Docker subnet, replication password kept in `.pgpass` (never in `primary_conninfo`), no `sudo`, port not published to the host.
- **Declarative config**: `repmgr.conf` and `pg_hba.conf` are templates rendered with `envsubst` at startup.
- **Self-healing entrypoint**: validates the environment, initializes primary / clones standby, registers the node, supervises `postgres` and `repmgrd`, and shuts down gracefully on `SIGTERM`.
- **Idempotent restarts**: existing `PGDATA` is checked for consistency with the configured role; a role/data mismatch refuses to start instead of silently wiping replication data.

## Repository layout

```
docker-compose.yml    # postgres service (primary node by default)
.env.example          # environment template (copy to .env; .env is git-ignored)
docker/Dockerfile     # postgres:17 + repmgr from the PGDG apt repository
docker/entrypoint.sh  # cluster init, node registration, repmgrd supervision
docs/ENTRYPOINT.md    # full entrypoint documentation
config/repmgr.conf    # repmgr config template (envsubst-rendered)
config/pg_hba.conf    # pg_hba template (scram-sha-256, Docker-subnet-only access)
```

## Quick start

```bash
cp .env.example .env
# edit passwords and node parameters
docker compose up -d --build
docker compose logs -f postgres
```

Expected final log line:

```
=== PostgreSQL node pg-node-1 (primary) is ready ===
```

## Key environment variables

| Variable | Purpose |
|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | superuser credentials and main database |
| `REPMGR_USER` / `REPMGR_PASSWORD` | replication/metadata user |
| `REPMGR_NODE_ROLE` | `primary` or `standby` |
| `REPMGR_NODE_NAME` / `REPMGR_NODE_ID` | unique cluster node name and numeric ID |
| `REPMGR_PRIMARY_HOST` | primary hostname (required for standby) |
| `REPMGR_UPSTREAM_NODE_ID` | upstream node ID for cascaded replication (standby only) |
| `DOCKER_SUBNET` / `NODE_IP` | compose network subnet and node address |
| `FORCE_REINIT` | `true` = wipe `PGDATA` and re-initialize when role/data mismatch (destructive, manual) |

See [docs/ENTRYPOINT.md](docs/ENTRYPOINT.md) for the full reference.

## Running a 3-node cluster

Run one copy of this project per node (or use a compose override), each with its own `.env`:

| | node 1 | node 2 | node 3 |
|---|---|---|---|
| `REPMGR_NODE_ROLE` | `primary` | `standby` | `standby` |
| `REPMGR_NODE_ID` | `1` | `2` | `3` |
| `REPMGR_NODE_NAME` / `NODE_DOMAIN` / `CONTAINER_NAME` | `pg-node-1` | `pg-node-2` | `pg-node-3` |
| `REPMGR_PRIMARY_HOST` | *(n/a)* | `pg-node-1` | `pg-node-1` |
| `REPMGR_UPSTREAM_NODE_ID` | *(empty)* | `1` | `1` |
| `NODE_IP` | `172.28.0.10` | `172.28.0.11` | `172.28.0.12` |

All nodes must share one Docker network (`postgres-network`) and resolve each other by hostname.

## Security model

- `scram-sha-256` only; `pg_hba.conf` allows connections from the Docker subnet (`DOCKER_SUBNET`) and loopback — no `0.0.0.0/0`.
- Replication password is read from `.pgpass` (`passfile` in `primary_conninfo`), so it never lands in `postgresql.auto.conf` or `SHOW ALL` output.
- The container starts as root and drops to `postgres` via `gosu` (same pattern as the official image); `sudo` is not installed.
- Port 5432 is not published to the host; access goes through the internal compose network only.
- Secrets are not committed: `.env` is git-ignored, `.env.example` contains placeholders.

## Operations

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

## Limitations

- `POSTGRES_DB` doubles as the repmgr metadata database; for production workloads consider a separate database for repmgr.
- Failover is automatic via `repmgrd`, but client rerouting (new primary discovery) is out of scope — add pgbouncer/HAProxy or a VIP manager in front.
- WAL archiving is disabled (`archive_mode=off`); for stricter durability configure synchronous standby or pgBackRest/wal-g.
