# Local compose overrides

Put your own `*.yml` compose overrides here (e.g. extra env, resource limits,
removing a service you don't need). `scripts/render.sh` layers every
`overrides/*.yml` on top of `upstream/docker-compose.yml` (in file-name order)
before generating `openship-compose.yml`, so your changes survive upgrades
without editing `upstream/`.

Paths: write bind sources relative to the upstream project dir, e.g.
`./volumes/custom/foo.conf`. Render maps `./volumes/<x>` to
`$SUPABASE_ROOT/config/<x>` (data dirs map to `$SUPABASE_ROOT/data/...`).
Put the file itself in `config.local/custom/foo.conf`; `render.sh`
regenerates `config/` from upstream and then copies `config.local/` over it.

Example `overrides/10-limits.yml`:

```yaml
services:
  db:
    deploy:
      resources:
        limits:
          memory: 2g
  auth:
    environment:
      GOTRUE_LOG_LEVEL: warn
```
