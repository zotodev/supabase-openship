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
.openship/workflows/supabase-*.yml      Openship Actions: one UI button per manager command
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
   `cd /srv/supabase && sh run.sh secrets` (or `cat .env`). This is deliberately
   **not** a UI button, see [Operations from the Openship UI](#operations-from-the-openship-ui).

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
manager compose logs --tail 200 auth   # bounded, no follow
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
* From the UI: the **Supabase: backup now** workflow (see below).
* Scheduled: Openship does not auto-detect `supabase/postgres`. Either
  **Jobs → New job → Run workflow** → *Supabase: backup now*, cron `0 3 * * *`,
  or a plain command Job (see the Jobs table below).
* Copy `/srv/supabase-backups` off the box (restic/rclone). The pgsodium key
  and `.env` are secrets.
* Restore (outline): stop the stack, restore `files.tar.gz` into
  `/srv/supabase`, start `db` only, then
  `zcat pg_dumpall.sql.gz | docker exec -i supabase-db psql -U supabase_admin -d postgres`
  on a fresh data dir, and put the pgsodium key in place *before* first start.
  Rehearse this on a scratch VM; it is not automated here.

## Operations from the Openship UI

`.openship/workflows/` holds one Openship Actions workflow per manager command.
They are **independent Openship workflows** (Openship runs them itself with its
act-based runner; GitHub ignores `.openship/`). Each one is
`workflow_dispatch` only, so a push never runs one and a run never deploys.
They are not in `autoDeployPaths`, and `.dockerignore` excludes `.openship/`,
so editing them never rebuilds or redeploys the manager.

| Workflow (button) | Inputs | Runs (inside the manager) | Timeout |
|---|---|---|---|
| Supabase: status | none | `manager status` + `manager health` (warns if unhealthy) | 5 min |
| Supabase: backup now | none | `manager backup`, then lists the backup dir | 60 min |
| Supabase: update | `to` (tag, empty = `SUPABASE_VERSION`), `dry_run` (**default on**) | `manager update [--to T] [--dry-run]` | 120 min |
| Supabase: reconcile | none | `manager reconcile` (re-apply env/overrides, update if needed, `run.sh start`) | 90 min |
| Supabase: logs | `service` (choice), `lines` (1-5000, default 200), `since` (optional) | `manager compose logs --tail N [--since S] <svc>` (no follow) | 5 min |
| Supabase: restart service | `service` (choice), `mode` = `restart` / `recreate` | `docker compose restart <svc>` or `up -d --wait --force-recreate --no-deps <svc>` (`recreate` applies `.env` changes) | 15 min |
| Supabase: secrets check (no values) | none | set/missing, 8-char sha256 fingerprints, flags `.env.example` defaults; prints only public values (URLs, `ANON_KEY`, publishable key, dashboard user) | 5 min |

Every workflow finds the manager with
`docker ps -q --filter label=openship.service=supabase-manager --filter status=running`
(Openship stamps `openship.service` on each compose service container; the
name `openship-<slug>-supabase-manager` briefly differs during a cutover) and
refuses unless exactly one matches. If you run more than one such project on
the server, set an Openship Actions **variable** `OPENSHIP_PROJECT_ID` to this
project's id to add `--filter label=openship.project=<id>`.

Update outcomes: exit 0 = done (or dry run / already on target); **3** =
refused before changing anything (breaking release not in `ACK_BREAKING`,
downgrade or bad tag); **2** = `update.sh` merge conflicts (containers not
recreated); anything else = failed. The run fails with a message for each.
If you update to a tag other than `SUPABASE_VERSION`, the run warns you to set
`SUPABASE_VERSION` to it, otherwise the next manager restart reconciles back
towards the old pin (a downgrade, refused, manager `blocked`).

### One-time setup

1. **Runner.** Actions → Runners → Add runner → **Existing server** (the VPS
   running Supabase). Either:
   * **Native Linux** (simplest): steps run as the server user Openship
     connects with. That user must be able to run `docker` (root, or in the
     `docker` group).
   * **Linux container** (e.g. the Ubuntu preset `catthehacker/ubuntu:act-22.04`,
     which has the docker CLI) with **Allow Docker access** enabled. The job
     container runs with the connected user's UID/GID, so that user must still
     be able to use `/var/run/docker.sock`.
2. **Import.** Project → Actions → select this repo/branch → tick the
   `.openship/workflows/supabase-*.yml` files (Select all) → Run settings:
   choose the runner from step 1 → save. They do not need to be "required"
   for deployments; leave the project's deployment automation as it is.
3. **Access.** Default is "Only my account" + **Approve each run**. For
   one-click buttons choose **Automatically allow eligible users** (keep
   access limited to your own account). Keep per-run approval if others can
   trigger workflows.
4. Optional: Actions variable `OPENSHIP_PROJECT_ID` (see above).

Then each workflow has a **Run** button with an input form. Live logs show in
the run page. Openship keeps run history for 30 days (logs up to 8 MiB per
job). Openship's own default timeout is 60 min, and the workflows set their
own `timeout-minutes`. For a nightly backup use **Jobs → New job → Run
workflow** (pick *Supabase: backup now*), or uncomment the `schedule:` block in
`supabase-backup.yml` (UTC; Openship runs independent schedules while its
controller is online, min. 5 min apart, no catch-up of missed runs).

### Security

* **A runner that can use Docker is root on the host**, the same as the
  manager's socket mount. Anyone who can edit these workflows (repo write
  access) or trigger them with auto-approval can control the server. Keep
  the repo private, protect `main`, and keep Actions access to your account.
* **There is no "show secrets" button, on purpose.** Run output is stored in
  Openship run history and can be included in notifications, so a
  workflow or Job printing `run.sh secrets` would copy your JWT secret,
  service-role key and DB password there. *Secrets check* prints fingerprints
  only (compare with `printf %s "$VALUE" | sha256sum | cut -c1-8`). As a second
  line of defence it registers every secret value with `::add-mask::` first,
  so the runner prints `***` if one ever shows up. To read a secret, use the
  manager's **Terminal** tab: `sh /srv/supabase/run.sh secrets`.
* Service **logs** are not masked. Supabase services normally don't log
  secrets, but treat log runs as sensitive.
* Plain Openship **Jobs** (below) do **not** mask anything: their output is
  stored as-is (200k chars, 30 days) and the last 20 lines go into
  notifications.

### Alternative: plain Openship Jobs

If you prefer Jobs (no runner, no repo files; created in the UI, the
`openship job` CLI or the API; run on the server's shell; no input
forms, so edit the job's env instead): **Jobs → New job**, pick the server,
schedule *manual* (or cron), and use the prefix below plus a command:

```sh
C=$(docker ps -q --filter label=openship.service=supabase-manager --filter status=running)
[ "$(printf '%s\n' "$C" | grep -c .)" = 1 ] || { echo "need exactly 1 running manager"; exit 1; }
```

| Job | Command (after the prefix) | Timeout |
|---|---|---|
| Supabase status | `docker exec "$C" manager status` | 1 min |
| Supabase backup (cron `0 3 * * *` if wanted) | `docker exec "$C" manager backup` | 60 min |
| Supabase update | `docker exec "$C" manager update ${TO:+--to "$TO"} ${DRY:+--dry-run}` (job env `TO=self-hosted/vX.Y.Z`, `DRY=1`) | 120 min |
| Supabase reconcile | `docker exec "$C" manager reconcile` | 90 min |
| Supabase logs auth | `docker exec "$C" manager compose logs --no-color --tail 200 auth` | 1 min |
| Supabase restart auth | `docker exec "$C" manager compose restart auth` | 5 min |

Never use `-t`/`-it` (no TTY), so `manager psql` does not work from Jobs or
workflows. Use the Terminal tab for that.

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

* Openship workflows (`.openship/workflows/`): `actionlint` + `yamllint`
  clean. Each one was run with `act` v0.2.89 (the act version Openship's
  runner pins), on the host (≈ native mode) and status in a
  `catthehacker/ubuntu:act-22.04` container with the socket (≈ container mode
  + Allow Docker access), against the built manager image and a stub stack
  (real upstream v0.8.3 `run.sh`/`update.sh`/`.env.example`, busybox/postgres
  services with upstream names). Passing: status, backup (real `pg_dumpall` +
  key), logs (tail, since, unknown service and bad `lines` rejected), restart and
  recreate, reconcile, update dry run from 0.8.2 (no files changed, no backup),
  update refused by the 0.8.0 gate (exit 3), update with merge conflicts
  (exit 2), bad tag, manager-not-found (0 and 2 matches, project filter).
  Secrets check: fingerprints match `sha256sum`, defaults flagged, none of the
  13 secret values appear in the raw log, and `::add-mask::` replaced a
  deliberately printed value with `***`.

Not verified / inferred:
* Inside a real Openship instance: workflow import, the runner label match
  (`[self-hosted, openship, linux]`), input forms, approvals, and the
  `vars.OPENSHIP_PROJECT_ID` variable. A runner running as a non-root user
  (Openship's container runner uses the connected user's UID/GID) was not
  tested.
* Openship behaviour: `build` with a repo-root context and `dockerfile` path,
  honouring `HEALTHCHECK`/healthcheck, env editor → container env, and the Job
  syntax/container naming.
* `upgrade-pg17.sh` from inside the container; the Kong→Envoy orphan note;
  the restore procedure.
* Your host's firewall/Tailscale specifics.
* Leftover `docker-compose.yml.old` in `/srv/supabase` comes from upstream
  `setup.sh` (`sed -i.old`); it is harmless.
