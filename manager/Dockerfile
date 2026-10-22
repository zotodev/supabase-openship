# supabase-manager: a small control container that drives the official
# self-hosted Supabase docker/ setup on the host via the host Docker socket.
FROM docker:29-cli

# bash: manager.sh; git/jq/curl/openssl: upstream setup.sh + update.sh;
# nodejs: upstream utils/add-new-auth-keys.sh (otherwise it falls back to
# `docker run node:22-alpine`); postgresql-client: optional ad-hoc psql/pg_dump;
# tini: proper PID 1 / signal handling; util-linux: flock; coreutils/findutils/
# tar/gzip/sed/grep/gawk: GNU behaviour the upstream scripts expect.
RUN apk add --no-cache \
        bash git jq curl openssl ca-certificates nodejs postgresql-client \
        tini util-linux coreutils findutils tar gzip sed grep gawk tzdata

COPY manager/manager.sh /opt/manager/manager.sh
COPY overrides/ /opt/manager/overrides/
COPY supabase.version /opt/manager/supabase.version
RUN chmod 0755 /opt/manager/manager.sh && ln -s /opt/manager/manager.sh /usr/local/bin/manager

ENV SUPABASE_DIR=/srv/supabase \
    BACKUP_DIR=/srv/supabase-backups
WORKDIR /srv/supabase

HEALTHCHECK --interval=30s --timeout=20s --start-period=15m --retries=3 CMD ["manager", "health"]
ENTRYPOINT ["/sbin/tini", "--", "manager"]
CMD ["run"]
