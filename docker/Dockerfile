ARG POSTGRES_VERSION=17
ARG PG_MAJOR=17
ARG REPMGR_VERSION=5.5.0
FROM postgres:${POSTGRES_VERSION}-bookworm

ARG PG_MAJOR
ARG REPMGR_VERSION

# repmgr берём из PGDG apt-репозитория (apt.postgresql.org) — он уже подключён
# в официальном образе postgres (см. https://repmgr.org/docs/current/installation-packages.html,
# раздел Debian/Ubuntu). Версия зафиксирована для воспроизводимой сборки.
# gosu уже входит в официальный образ; gettext-base (envsubst) ставим явно.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base "postgresql-${PG_MAJOR}-repmgr~=${REPMGR_VERSION}*" \
    && rm -rf /var/lib/apt/lists/*

# sudo не устанавливается: контейнер стартует от root и понижает права через gosu (см. entrypoint).
RUN mkdir -p /var/log/repmgr /var/lib/postgresql /var/run/repmgr \
    && chown -R postgres:postgres /var/log/repmgr /var/lib/postgresql /var/run/repmgr

COPY ./config/repmgr.conf /var/lib/postgresql/repmgr.conf.template
COPY ./docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Симлинк на сгенерированный конфиг создаётся в entrypoint (файла может не быть на момент сборки)
RUN chmod +x /usr/local/bin/entrypoint.sh

# Стартуем от root: entrypoint сам понижает права через gosu (как официальный образ postgres)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]