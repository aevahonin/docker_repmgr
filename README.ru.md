# PostgreSQL с repmgr в Docker

[English](README.md) | **Русский**

Docker-окружение для кластера PostgreSQL под управлением [repmgr](https://repmgr.org/) — репликация primary/standby с автоматическим failover.

> **Примечание:** документация и комментарии в коде в этом репозитории — на английском; исходные рабочие записи были на русском.

## Возможности

- **PostgreSQL 17 + repmgr 5.5** (зафиксированные версии, поверх официального образа `postgres`).
- **Автоматический failover** через `repmgrd` (`failover automatic`), replication slots включены.
- **Безопасность по умолчанию**: только аутентификация `scram-sha-256`, `pg_hba.conf` ограничен Docker-подсетью, пароль репликации хранится в `.pgpass` (не в `primary_conninfo`), `sudo` не устанавливается, порт не публикуется на хост.
- **Декларативный конфиг**: `repmgr.conf` и `pg_hba.conf` — шаблоны, рендерятся через `envsubst` при старте.
- **Самовосстанавливающийся entrypoint**: проверяет окружение, инициализирует primary / клонирует standby, регистрирует ноду, supervise'ит `postgres` и `repmgrd` и корректно завершается по `SIGTERM`.
- **Идемпотентные перезапуски**: существующий `PGDATA` проверяется на соответствие настроенной роли; при несовпадении роли и данных нода отказывается стартовать, вместо того чтобы молча затирать данные репликации.

## Структура репозитория

```
docker-compose.yml    # сервис postgres (по умолчанию — primary-нода)
.env.example          # шаблон окружения (скопируйте в .env; .env в git не попадает)
docker/Dockerfile     # postgres:17 + repmgr из apt-репозитория PGDG
docker/entrypoint.sh  # инициализация кластера, регистрация ноды, supervision repmgrd
docs/ENTRYPOINT.md    # полная документация entrypoint
config/repmgr.conf    # шаблон конфига repmgr (рендерится через envsubst)
config/pg_hba.conf    # шаблон pg_hba (scram-sha-256, доступ только из Docker-подсети)
```

## Быстрый старт

```bash
cp .env.example .env
# задайте пароли и параметры нод
docker compose up -d --build
docker compose logs -f postgres
```

Ожидаемая последняя строка лога:

```
=== PostgreSQL node pg-node-1 (primary) is ready ===
```

## Ключевые переменные окружения

| Переменная | Назначение |
|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | креды суперпользователя и основная база |
| `REPMGR_USER` / `REPMGR_PASSWORD` | пользователь репликации/метаданных |
| `REPMGR_NODE_ROLE` | `primary` или `standby` |
| `REPMGR_NODE_NAME` / `REPMGR_NODE_ID` | уникальные имя и числовой ID ноды кластера |
| `REPMGR_PRIMARY_HOST` | хост primary (обязателен для standby) |
| `REPMGR_UPSTREAM_NODE_ID` | ID upstream-ноды для каскадной репликации (только для standby) |
| `DOCKER_SUBNET` / `NODE_IP` | подсеть compose-сети и адрес ноды |
| `FORCE_REINIT` | `true` = затереть `PGDATA` и переинициализироваться при несовпадении роли/данных (destructive, вручную) |

Полный справочник — в [docs/ENTRYPOINT.md](docs/ENTRYPOINT.md).

## Запуск кластера из трёх нод

Запускайте по одной копии проекта на ноду (или используйте compose override), у каждой свой `.env`:

| | нода 1 | нода 2 | нода 3 |
|---|---|---|---|
| `REPMGR_NODE_ROLE` | `primary` | `standby` | `standby` |
| `REPMGR_NODE_ID` | `1` | `2` | `3` |
| `REPMGR_NODE_NAME` / `NODE_DOMAIN` / `CONTAINER_NAME` | `pg-node-1` | `pg-node-2` | `pg-node-3` |
| `REPMGR_PRIMARY_HOST` | *(н/д)* | `pg-node-1` | `pg-node-1` |
| `REPMGR_UPSTREAM_NODE_ID` | *(пусто)* | `1` | `1` |
| `NODE_IP` | `172.28.0.10` | `172.28.0.11` | `172.28.0.12` |

Все ноды должны находиться в одной Docker-сети (`postgres-network`) и резолвить имена друг друга.

## Модель безопасности

- Только `scram-sha-256`; `pg_hba.conf` пускает подключения из Docker-подсети (`DOCKER_SUBNET`) и с loopback — никакого `0.0.0.0/0`.
- Пароль репликации читается из `.pgpass` (`passfile` в `primary_conninfo`), поэтому не попадает в `postgresql.auto.conf` и вывод `SHOW ALL`.
- Контейнер стартует от root и переключается на `postgres` через `gosu` (тот же приём, что в официальном образе); `sudo` не устанавливается.
- Порт 5432 не публикуется на хост; доступ только через внутреннюю compose-сеть.
- Секреты не коммитятся: `.env` в gitignore, `.env.example` содержит плейсхолдеры.

## Эксплуатация

```bash
# Статус кластера (с любой ноды)
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf cluster show

# Статус ноды и репликации
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf node status
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf node check

# Демон repmgrd
docker compose exec postgres gosu postgres repmgr -f /var/lib/postgresql/repmgr.conf daemon status

# Логи
docker compose logs -f postgres                                  # stdout entrypoint + PostgreSQL
docker compose exec postgres tail -f /var/log/repmgr/repmgr.log  # лог repmgrd
```

## Ограничения

- `POSTGRES_DB` совмещён с базой метаданных repmgr; для продакшен-нагрузок лучше выделить repmgr отдельную базу.
- Failover автоматический, через `repmgrd`, но переподключение клиентов (обнаружение нового primary) остаётся за пределами скоупа — поставьте спереди pgbouncer/HAProxy или менеджер VIP.
- Архивация WAL выключена (`archive_mode=off`); для более строгой долговечности настройте синхронный standby или pgBackRest/wal-g.
