#!/bin/bash
# Entrypoint для PostgreSQL + repmgr контейнера.
# Стартует от root и понижает права до postgres через gosu (как официальный образ postgres).
set -Eeuo pipefail

trap 'echo "ERROR at line $LINENO" >&2' ERR

# --- Конфигурация по умолчанию ---------------------------------------------
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PG_HBA_SOURCE="${PG_HBA_SOURCE:-/etc/pg_hba.conf.template}"
PG_HBA_TARGET="${PG_HBA_TARGET:-$PGDATA/pg_hba.conf}"
REPMGR_CONF_TEMPLATE="${REPMGR_CONF_TEMPLATE:-/var/lib/postgresql/repmgr.conf.template}"
REPMGR_CONF="${REPMGR_CONF:-/var/lib/postgresql/repmgr.conf}"
REPMGR_LOG_FILE="${REPMGR_LOG_FILE:-/var/log/repmgr/repmgr.log}"
REPMGR_RUN_DIR="/var/run/repmgr"

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${REPMGR_USER:?REPMGR_USER is required}"
: "${REPMGR_PASSWORD:?REPMGR_PASSWORD is required}"
: "${REPMGR_NODE_NAME:?REPMGR_NODE_NAME is required}"
: "${REPMGR_NODE_ID:?REPMGR_NODE_ID is required}"
: "${REPMGR_NODE_ROLE:?REPMGR_NODE_ROLE is required (primary|standby)}"
: "${NODE_DOMAIN:?NODE_DOMAIN is required}"

# Валидация роли
if [ "$REPMGR_NODE_ROLE" != "primary" ] && [ "$REPMGR_NODE_ROLE" != "standby" ]; then
    echo "ERROR: REPMGR_NODE_ROLE must be 'primary' or 'standby', got: '$REPMGR_NODE_ROLE'" >&2
    exit 1
fi
if [ "$REPMGR_NODE_ROLE" = "standby" ] && [ -z "${REPMGR_PRIMARY_HOST:-}" ]; then
    echo "ERROR: REPMGR_PRIMARY_HOST is required when REPMGR_NODE_ROLE=standby" >&2
    exit 1
fi
if ! [[ "$REPMGR_NODE_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: REPMGR_NODE_ID must be a positive integer, got: '$REPMGR_NODE_ID'" >&2
    exit 1
fi

# Подсеть для pg_hba: по умолчанию - приватные диапазоны docker-сетей.
DOCKER_SUBNET="${DOCKER_SUBNET:-172.16.0.0/12}"

REPMGR_PRIMARY_HOST="${REPMGR_PRIMARY_HOST:-localhost}"
REPMGR_UPSTREAM_NODE_ID="${REPMGR_UPSTREAM_NODE_ID:-}"
REPMGR_PRIORITY="${REPMGR_PRIORITY:-100}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
LISTEN_ADDRESSES="${LISTEN_ADDRESSES:-*}"
MAX_WAL_SENDERS="${MAX_WAL_SENDERS:-10}"
MAX_REPLICATION_SLOTS="${MAX_REPLICATION_SLOTS:-10}"
WAL_LEVEL="${WAL_LEVEL:-replica}"
WAL_KEEP_SIZE="${WAL_KEEP_SIZE:-1GB}"

# --- Ожидание готовности ---------------------------------------------------
wait_for_pg() {
    # host может быть пустым - тогда проверяем через unix-сокет (не зависит от listen_addresses)
    local host=${1:-} max_attempts=${2:-60} attempt=0
    local -a host_args=()
    [ -n "$host" ] && host_args=(-h "$host")
    echo "Waiting for PostgreSQL${host:+ on $host}..."
    until pg_isready "${host_args[@]}" -p "$POSTGRES_PORT" -t 2 -q; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "ERROR: PostgreSQL${host:+ on $host} not ready after $max_attempts attempts" >&2
            return 1
        fi
        sleep 2
    done
    echo "PostgreSQL${host:+ on $host} is ready"
}

wait_for_primary() {
    if [ "$REPMGR_NODE_ROLE" = "standby" ] && [ -n "${REPMGR_PRIMARY_HOST:-}" ]; then
        wait_for_pg "$REPMGR_PRIMARY_HOST" 120
    fi
}

# --- Генерация конфигов через envsubst (вместо хрупких sed-конвейеров) -----
echo "Generating repmgr configuration from template..."
[ -f "$REPMGR_CONF_TEMPLATE" ] || { echo "ERROR: template not found: $REPMGR_CONF_TEMPLATE" >&2; exit 1; }

export REPMGR_NODE_ID REPMGR_NODE_NAME REPMGR_NODE_ROLE REPMGR_USER POSTGRES_DB \
       REPMGR_PASSWORD PGDATA REPMGR_LOG_FILE REPMGR_PRIORITY NODE_DOMAIN \
       POSTGRES_PORT REPMGR_UPSTREAM_NODE_ID
envsubst < "$REPMGR_CONF_TEMPLATE" > "$REPMGR_CONF"

# upstream_node_id обязателен только у standby; для primary убираем строку
if [ "$REPMGR_NODE_ROLE" != "standby" ] || [ -z "$REPMGR_UPSTREAM_NODE_ID" ]; then
    sed -i '/^upstream_node_id[[:space:]]/d' "$REPMGR_CONF"
fi

ln -sf "$REPMGR_CONF" /etc/repmgr.conf
echo "Generated repmgr configuration at: $REPMGR_CONF"

# --- .pgpass: единственный источник паролей для клиентских утилит ----------
PGPASSFILE_PATH="/var/lib/postgresql/.pgpass"
cat > "$PGPASSFILE_PATH" <<PEOF
$REPMGR_PRIMARY_HOST:$POSTGRES_PORT:$POSTGRES_DB:$REPMGR_USER:$REPMGR_PASSWORD
*:*:*:$REPMGR_USER:$REPMGR_PASSWORD
*:*:*:$POSTGRES_USER:$POSTGRES_PASSWORD
PEOF
chmod 600 "$PGPASSFILE_PATH"
chown postgres:postgres "$PGPASSFILE_PATH"   # файл читают psql/repmgr под пользователем postgres
export PGPASSFILE="$PGPASSFILE_PATH"

# --- Права на данные -------------------------------------------------------
mkdir -p "$PGDATA" "$REPMGR_RUN_DIR"
chown -R postgres:postgres "$PGDATA" "$REPMGR_RUN_DIR" /var/lib/postgresql /var/log/repmgr

# --- Инициализация кластера -------------------------------------------------
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    if [ "$REPMGR_NODE_ROLE" = "primary" ]; then
        echo "Initializing PRIMARY cluster..."
        rm -rf "$PGDATA"/*
        gosu postgres initdb -D "$PGDATA" -U "$POSTGRES_USER" \
            -A scram-sha-256 --pwfile=<(echo "$POSTGRES_PASSWORD") \
            --data-checksums

        cat >> "$PGDATA/postgresql.conf" <<CEOF
listen_addresses = '$LISTEN_ADDRESSES'
port = $POSTGRES_PORT
max_wal_senders = $MAX_WAL_SENDERS
max_replication_slots = $MAX_REPLICATION_SLOTS
wal_level = $WAL_LEVEL
hot_standby = on
wal_keep_size = $WAL_KEEP_SIZE
password_encryption = scram-sha-256
archive_mode = off
shared_preload_libraries = 'repmgr'
CEOF

        # Явный список переменных: DOCKER_SUBNET не экспортируется глобально, иначе envsubst
    # оставил бы литерал ${DOCKER_SUBNET} в pg_hba и сломал бы аутентификацию
    envsubst '${DOCKER_SUBNET} ${REPMGR_USER} ${POSTGRES_DB}' < "$PG_HBA_SOURCE" > "$PG_HBA_TARGET"

        echo "Starting temporary PostgreSQL for setup..."
        gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses='127.0.0.1' -c shared_preload_libraries=repmgr" -w start
        wait_for_pg   # local unix socket - независим от listen_addresses

        echo "Creating repmgr user and database..."
        gosu postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" <<-SEOSQL
        SET password_encryption = 'scram-sha-256';
        CREATE USER $REPMGR_USER WITH SUPERUSER LOGIN PASSWORD '$REPMGR_PASSWORD';
        CREATE DATABASE $POSTGRES_DB OWNER $REPMGR_USER;
        GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $REPMGR_USER;
SEOSQL

        gosu postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS repmgr;"

        echo "Registering primary node..."
        gosu postgres repmgr -f "$REPMGR_CONF" primary register --force

        echo "Stopping temporary PostgreSQL..."
        gosu postgres pg_ctl -D "$PGDATA" -m fast stop
    else
        echo "Initializing STANDBY cluster..."
        wait_for_primary

        echo "Cloning data from primary $REPMGR_PRIMARY_HOST..."
        # Пароль берётся из .pgpass - в primary_conninfo его не встраиваем
        gosu postgres repmgr -f "$REPMGR_CONF" \
            -h "$REPMGR_PRIMARY_HOST" -U "$REPMGR_USER" -d "$POSTGRES_DB" \
            standby clone --force

        # primary_conninfo без пароля: пароль читается из passfile, не попадает в auto.conf в открытом виде
        cat >> "$PGDATA/postgresql.auto.conf" <<AEOF
primary_conninfo = 'host=$REPMGR_PRIMARY_HOST port=$POSTGRES_PORT user=$REPMGR_USER application_name=$REPMGR_NODE_NAME connect_timeout=5 passfile=''$PGPASSFILE_PATH'''
AEOF
        chown postgres:postgres "$PGDATA/postgresql.auto.conf"
    fi
else
    echo "PostgreSQL cluster already exists, checking state consistency..."
    # Ожидаемый маркер данных для роли: standby.signal есть только у standby
    is_standby_data=$([ -f "$PGDATA/standby.signal" ] && echo yes || echo no)
    want_standby=$([ "$REPMGR_NODE_ROLE" = "standby" ] && echo yes || echo no)

    if [ "$is_standby_data" != "$want_standby" ]; then
        if [ "$FORCE_REINIT" = "true" ]; then
            echo "WARNING: FORCE_REINIT=true - wiping PGDATA ($PGDATA) and re-initializing as $REPMGR_NODE_ROLE!"
            gosu postgres pg_ctl -D "$PGDATA" -m immediate stop 2>/dev/null || true
            rm -rf "$PGDATA"/*
            exec "$0"   # начинаем заново: пустой PGDATA -> обычный путь инициализации
        fi
        if [ "$want_standby" = "yes" ]; then
            echo "ERROR: PGDATA exists but is not a standby (standby.signal missing)." >&2
            echo "The previous clone likely failed midway. Set FORCE_REINIT=true and restart to re-clone." >&2
        else
            echo "ERROR: PGDATA is a standby, but REPMGR_NODE_ROLE=primary. Refusing to start" >&2
            echo "to protect replication data. Re-configure the node or set FORCE_REINIT=true." >&2
        fi
        exit 1
    fi
    echo "State matches role ($REPMGR_NODE_ROLE)"
    # Обновляем pg_hba на существующем кластере, чтобы применить актуальные правила
    # Явный список переменных: DOCKER_SUBNET не экспортируется глобально, иначе envsubst
    # оставил бы литерал ${DOCKER_SUBNET} в pg_hba и сломал бы аутентификацию
    envsubst '${DOCKER_SUBNET} ${REPMGR_USER} ${POSTGRES_DB}' < "$PG_HBA_SOURCE" > "$PG_HBA_TARGET"
    chown postgres:postgres "$PG_HBA_TARGET"
fi

# --- Старт основного процесса -----------------------------------------------
if [ "$REPMGR_NODE_ROLE" = "standby" ]; then
    wait_for_primary
fi

echo "Starting PostgreSQL as $REPMGR_NODE_ROLE..."
gosu postgres postgres -D "$PGDATA" -c "listen_addresses=$LISTEN_ADDRESSES" -c shared_preload_libraries=repmgr &
POSTGRES_PID=$!
SHUTDOWN=0
on_term() {
    echo "Received shutdown signal, stopping PostgreSQL and repmgrd..."
    SHUTDOWN=1
    kill -TERM "$POSTGRES_PID" 2>/dev/null || true
}
trap on_term TERM INT

wait_for_pg   # local unix socket - независим от listen_addresses

echo "Checking repmgr extension..."
gosu postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_extension WHERE extname='repmgr'" | grep -q 1 || {
    echo "Creating repmgr extension..."
    gosu postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION repmgr;"
}

if ! gosu postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
     "SELECT 1 FROM repmgr.nodes WHERE node_name='$REPMGR_NODE_NAME'" | grep -q 1; then
    echo "Node not registered, registering as $REPMGR_NODE_ROLE..."
    if [ "$REPMGR_NODE_ROLE" = "primary" ]; then
        gosu postgres repmgr -f "$REPMGR_CONF" primary register --force
    else
        attempt=0
        until gosu postgres repmgr -f "$REPMGR_CONF" standby register --force; do
            attempt=$((attempt + 1))
            [ "$attempt" -ge 3 ] && { echo "ERROR: standby registration failed after 3 attempts" >&2; exit 1; }
            echo "Registration attempt $attempt failed, retrying in 10s..."
            sleep 10
        done
    fi
else
    echo "Node already registered"
fi

gosu postgres repmgr -f "$REPMGR_CONF" cluster show || true

# --- Запуск repmgrd ---------------------------------------------------------
PIDFILE="$REPMGR_RUN_DIR/repmgrd.pid"
rm -f "$PIDFILE"
echo "Starting repmgrd..."
gosu postgres repmgrd -f "$REPMGR_CONF" --pid-file="$PIDFILE" -d
sleep 2

echo "=== PostgreSQL node $REPMGR_NODE_NAME ($REPMGR_NODE_ROLE) is ready ==="

# --- Главный цикл наблюдения: падаем, если умер PostgreSQL или repmgrd ------
while :; do
    if [ "$SHUTDOWN" = "1" ]; then
        wait "$POSTGRES_PID" || true
        if [ -f "$PIDFILE" ]; then
            kill -TERM "$(cat "$PIDFILE")" 2>/dev/null || true
            rm -f "$PIDFILE"
        fi
        echo "Shutdown complete"
        exit 0
    fi
    if ! kill -0 "$POSTGRES_PID" 2>/dev/null; then
        echo "ERROR: PostgreSQL process died" >&2
        exit 1
    fi
    if [ -f "$PIDFILE" ] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "WARNING: repmgrd died, restarting..."
        rm -f "$PIDFILE"
        gosu postgres repmgrd -f "$REPMGR_CONF" --pid-file="$PIDFILE" -d
    fi
    sleep 30 &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
done
