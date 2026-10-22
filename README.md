# supabase-openship

Self-hosted Supabase (the **official** `docker/` setup from
[supabase/supabase](https://github.com/supabase/supabase/tree/master/docker),
pinned in `supabase.version`, currently `self-hosted/v0.8.3`) on your own VPS,
deployed and redeployed through [Openship](https://openship.io).

## How it works

Openship deploys **one** service, `supabase-manager` (`openship-compose.yml`),
built from `manager/Dockerfile` (`docker:29-cli` + bash, jq, git, curl,
pg tools). The manager:

* mounts the host Docker socket and `/srv/supabase:/srv/supabase` (**same path
  inside and outside**, so the relative `./volumes/...` bind mounts that
  compose sends to the host daemon resolve correctly);
* runs upstream's own `setup.sh`, `update.sh`, and `run.sh` **unmodified**, so
  the real stack runs under genuine `docker compose` (project `supabase`).
  `container_name`, network aliases (`realtime-dev.supabase-realtime`, `kong`),
  `COMPOSE_FILE` overrides, logging options, and `env_file` all behave exactly
  as upstream documents;
* on every start (every Openship deploy) it *reconciles*:

| situation | what the manager does |
|---|---|
| `/srv/supabase` empty | `setup.sh --skip-deps -y --ref <tag>`: secrets are generated **on the host** into `/srv/supabase/.env` (mode 600, never in git), then the overrides in `COMPOSE_OVERRIDES` are applied via `run.sh config add`, then `run.sh start` |
| installed version == target | apply overrides and `SUPABASE_ENV_*`, then `run.sh start` (idempotent `up -d --wait`) |
| target is newer | pre-update backup (pg_dumpall, pgsodium root key, `.env`, compose files, storage/snippets/functions) → `update.sh --to <tag> --yes` → `run.sh pull && run.sh recreate` |
| target crosses a release marked breaking or gated in upstream `upgrades.json` and not listed in `ACK_BREAKING` | **refuses**; nothing is changed, the current version stays running, state `blocked` |
| `update.sh` reports merge conflicts (exit 2) | **stops**; containers are not recreated and keep running the old version, state `blocked` |
| downgrade / non-tag target | refuses (`blocked`) |

The manager then stays up. Its Docker `HEALTHCHECK` (`manager health`) fails
while the state is `blocked` or `error`, or while any Supabase service is not
running or healthy, so Openship shows the manager as **unhealthy**. It
deliberately does *not* exit on failure, which would cause a restart loop that
repeats backups. Read `docker logs` / the Openship logs for the reason.

**SIGTERM / redeploy / stop of the manager never stops Supabase.** The
manager exits 0 and the Supabase containers (restart `unless-stopped`) keep
running. Verified: 11 of 11 containers stayed up after `docker stop` and
`docker rm -f` of the manager. To actually stop Supabase, run
`manager compose stop` (or `down`).

## Repo layout

```
openship.json                      Openship: composePath + autoDeployPaths
openship-compose.yml               the single supabase-manager service
supabase.version                   pinned upstream tag (default target)
manager/Dockerfile                 manager image
manager/manager.sh                 entrypoint + CLI (`manager help`)
overrides/docker-compose.logrotate.yml  local log driver, 10m x 3 (db 20m x 5)
overrides/docker-compose.tailnet.yml    publish ports only on BIND_IP
```

Nothing from upstream is vendored: the manager downloads the tag's files.
Your live config (`.env`, merged compose files, `volumes/`) lives on the host
in `/srv/supabase`, and `update.sh` 3-way-merges upstream changes into it.

## Openship setup

1. Push this repo to a **private** GitHub repo. Connect it in Openship as a
   project on your **own server** target. Openship reads `openship.json`
   (`composePath: openship-compose.yml`).
2. On the server, once: `sudo mkdir -p /srv/supabase /srv/supabase-backups`.
   (Docker would create them anyway, but creating them yourself makes the
   ownership obvious.)
3. Environment, in the Openship env editor (all optional except the URLs):

   ```
   COMPOSE_OVERRIDES=logrotate tailnet
   SUPABASE_ENV_BIND_IP=100.x.y.z                # tailscale ip -4 (tailnet override)
   SUPABASE_ENV_SUPABASE_PUBLIC_URL=https://supabase.<tailnet>.ts.net
   SUPABASE_ENV_API_EXTERNAL_URL=https://supabase.<tailnet>.ts.net
   SUPABASE_ENV_SITE_URL=https://app.example.com
   SUPABASE_ENV_SMTP_HOST=...  (SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_ADMIN_EMAIL, ...)
   # SUPABASE_VERSION=self-hosted/v0.8.3          # overrides supabase.version
   # ACK_BREAKING=0.8.0                           # see "Upgrades"
   # AUTO_UPDATE=false
   # BACKUP_KEEP_DAYS=14
   # TZ=Asia/Kolkata                              # manager log timestamps (default UTC)
   ```

   Every `SUPABASE_ENV_<KEY>=<value>` is written into `/srv/supabase/.env` as
   `KEY=<value>` on every reconcile. **Overriding secrets** (optional): you
   may also set `SUPABASE_ENV_POSTGRES_PASSWORD`, `SUPABASE_ENV_JWT_SECRET`,
   and so on. They are applied *after* first-install generation, so prefer
   letting `setup.sh` generate them. Changing `POSTGRES_PASSWORD` or
   `JWT_SECRET` on an existing install does **not** rotate them in the
   database or the keys. Follow upstream's docs for rotation.
4. Deploy. The first run pulls about 11 images and waits for health. The
   healthcheck start period is 15 min.
5. Retrieve the generated keys: in the Openship terminal for the manager (or
   `ssh` + `docker exec -it <manager> sh`), run
   `cd /srv/supabase && sh run.sh secrets` (or `cat .env`).

### Exposure (important)

Upstream publishes the API gateway on `0.0.0.0:8000` and Supavisor on
`:5432`/`:6543` (all interfaces). Docker-published ports bypass ufw.
Choose one:

* `COMPOSE_OVERRIDES=... tailnet` + `SUPABASE_ENV_BIND_IP=<tailscale IP>` to
  publish only on the tailnet (verified with `docker compose config`: all
  three ports get `host_ip`), **or**
* `SUPABASE_ENV_BIND_IP=127.0.0.1` + `sudo tailscale serve --bg 8000` for HTTPS
  on `https://<host>.<tailnet>.ts.net`, with URLs set to match.

The manager container itself publishes **no ports**.

### What Openship shows

Openship only knows the `supabase-manager` container: its logs, its health,
and its terminal. The Supabase containers are not Openship-managed, so
Openship's log rotation (20MB×3), metrics, and per-service views do not apply
to them. Use:

```
manager status            # state + docker compose ps
manager logs auth         # follows (-f), Ctrl-C to stop; any service name
manager psql              # psql as postgres in supabase-db
manager compose <args>    # any docker compose command in /srv/supabase
```

## Upgrades

1. Read upstream's [Updating guide](https://supabase.com/docs/guides/self-hosting/updating)
   and `CHANGELOG.md` for the target tag.
2. Bump `supabase.version` (commit; it is in `autoDeployPaths`) **or** set
   `SUPABASE_VERSION` in Openship, then Redeploy.
3. Watch the manager logs. It prints upstream's `upgrades.json` notes for the
   range, then: backup, then `update.sh`, then pull + recreate, then `state=ok`.

**Blocked: breaking or gated release.** The log says which versions, for
example `0.8.0`. Do the manual steps from the changelog/upgrades.json, then set
`ACK_BREAKING=0.8.0` (comma list) and redeploy. `AUTO_UPDATE` never crosses
these releases.

**Postgres major gate (0.6.0, `utils/upgrade-pg17.sh`).** Run this **on the
host over SSH with sudo**, from `/srv/supabase`, then set the ACK and
redeploy. It needs root and host paths. Running it from inside the manager
container is *untested*. Paths are identical and the socket is available, so
it might work, but don't rely on it. (Only relevant for installs older than
0.6.0; a fresh 0.8.x install is already on PG17.)

**Blocked: conflicts.** Your local edits clashed with upstream. The files
with `<<<<<<<` markers are listed in the log. Containers were not recreated,
so the old version keeps serving. Resolve the markers (Openship terminal or
SSH, in `/srv/supabase`), then `manager compose config -q` to validate, then
`manager update` (or redeploy). Backups made before the update are in
`/srv/supabase-backups/<ts>-pre-<ver>`, and `update.sh` keeps its own copy in
`/srv/supabase/backups/`.

**Crossing 0.8.0 (Kong → Envoy) on an old install:** the `kong` service is
renamed `api-gw`. If the old `supabase-kong` container lingers and holds port
8000, run `manager compose up -d --remove-orphans`. (Inferred, not tested.)

Don't kill (`docker kill`) the manager mid-update. A normal stop (SIGTERM)
during an update ends the update step, so check `manager status` afterwards.

## Backups

* Automatic before every update (once per target version).
* Manual: `manager backup`, which writes `$BACKUP_DIR/<ts>-manual/`:
  `pg_dumpall.sql.gz`, `pgsodium_root.key`, and `files.tar.gz` (`.env`,
  version stamp, compose files, `volumes/storage`, `snippets`, `functions`).
  Retention is `BACKUP_KEEP_DAYS`.
* Scheduled: Openship does not auto-detect `supabase/postgres`. Add an
  Openship **Job** (cron, runs over SSH on the host), for example daily:
  `docker exec $(docker ps -qf name=supabase-manager) manager backup`.
  Openship may prefix the container name; adjust the filter.
* Copy `/srv/supabase-backups` off the box (restic/rclone). The pgsodium key
  and `.env` are secrets.
* Restore (outline): stop the stack, restore `files.tar.gz` into
  `/srv/supabase`, start `db` only, then
  `zcat pg_dumpall.sql.gz | docker exec -i supabase-db psql -U supabase_admin -d postgres`
  on a fresh data dir, and put the pgsodium key in place *before* first start.
  Rehearse this on a scratch VM; it is not automated here.

## Security

* **`/var/run/docker.sock` = root on the host.** Anyone who can exec into the
  manager, change this repo, or edit the Openship project env can take over
  the server. Keep the repo private, protect the default branch, and restrict
  who has access to the Openship project and terminal.
* No ports on the manager. Secrets never enter git: `.env` is generated on
  the host and `.gitignore` excludes `.env*`. Openship env values (if you
  override secrets) are stored by Openship.
* Backups are root-only (`0700`/`0600`).

## Adopting an existing install

If `/srv/supabase` already contains an upstream install with a
`.supabase-version` stamp, the manager adopts it: no install, overrides and env
are applied, and it updates if needed. A non-empty directory **without** the
stamp is refused rather than overwritten. For an older upstream install without
a stamp, create it yourself (`echo ref=self-hosted/vX.Y.Z > .supabase-version`,
with the tag you actually installed) so `update.sh` merges from the right base.

## Alternative (not used)

Branch `alt-flatten` has an earlier design: render the upstream compose
into one flattened file for Openship's native compose deployer (no socket
mount). It needs workarounds for things Openship ignores (`container_name`,
aliases, `COMPOSE_FILE`, `logging`, `env_file`), host-side config sync, and
Jobs for upgrades. It was dropped in favour of the manager.

## Verified vs inferred

Verified (on a test box with a real Docker 28.5 daemon):
* `shellcheck` clean; `docker compose config` valid for `openship-compose.yml`;
  logrotate override merges into all 11 services; tailnet override binds all 3
  ports.
* Image builds (`docker:29-cli`: compose v5.6.1, bash 5.3, jq, node 24, pg_dumpall 18).
* **Real end-to-end** with the built image and the socket mounted: fresh
  install of v0.8.2 gave all 11 services healthy, `.env` 600, the logging
  driver `local` 10m×3 / db 20m×5 applied, and `/auth/v1/health` 200 through
  the gateway. Redeploy with `SUPABASE_VERSION=self-hosted/v0.8.3` gave
  backup → update.sh (0 conflicts) → pull/recreate → all healthy on 0.8.3
  images. `manager backup` (real dump, 16 roles) and `manager status` worked.
  Stopping or removing the manager left all 11 containers running.
* Stubbed docker, real upstream scripts: 0.7.2→0.8.3 is blocked by the 0.8.0
  breaking entry (stack untouched, health fails, current version kept up);
  `ACK_BREAKING=0.8.0` proceeds; a local edit is reported as a conflict and
  the stack is not recreated.

Not verified / inferred:
* Openship behaviour: `build` with a repo-root context and `dockerfile` path,
  honouring `HEALTHCHECK`/healthcheck, env editor → container env, and the Job
  syntax/container naming.
* `upgrade-pg17.sh` from inside the container; the Kong→Envoy orphan note;
  the restore procedure.
* Your host's firewall/Tailscale specifics.
* Leftover `docker-compose.yml.old` in `/srv/supabase` comes from upstream
  `setup.sh` (`sed -i.old`); it is harmless.
