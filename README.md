# odoo-railway

Thin wrapper around the official `odoo:19.0` image for the Railway template
`Odoo | (Just Updated) ERP & CRM Nobody Else Can Log Into`.

Image: `ghcr.io/bon5co/odoo-railway:19.0`

## Why a wrapper is unavoidable

Odoo has no environment-variable configuration layer. Every setting that makes a
public deploy safe — `admin_passwd`, `list_db`, `dbfilter`, `proxy_mode` — exists
only in `odoo.conf` or as a CLI flag, so a Railway template variable cannot set
any of them. A published listing that ships an `ADMIN_PASSWD` variable is
publishing a variable nothing reads.

## What it changes, all measured against the published listings on 2026-08-11

1. **The database manager is closed and the master password is real.**
   `admin_passwd` defaults to `admin` and `list_db` defaults to `True`. Against
   the category leader's exact configuration, an anonymous
   `POST /web/database/backup` with `master_pwd=admin` returned a **528 KB ZIP**
   containing `dump.sql` and the filestore. The same endpoint set also drops and
   restores databases. Here `admin_passwd` comes from `${{secret(32)}}` and
   `list_db = False`, so the same request returns *"The database manager has been
   disabled by the administrator"*.
2. **The administrator password is seeded, and rotates by redeploy.** Odoo
   initialises a database with login `admin` / password `admin`, and no upstream
   env var changes it. Both bootable listings answered those credentials with
   `303` and `is_admin: true`. `seed_admin.py` runs on every boot before anything
   binds a port, so a redeploy rotates the password; the container refuses to
   boot on an empty `ODOO_ADMIN_PASSWORD`.
3. **It boots.** The stock `/entrypoint.sh` reads `$PORT` as the *Postgres* port
   (`check_config "db_port" "$PORT"`) and Railway injects `PORT=8080` into every
   service. Two published listings pass `ODOO_DATABASE_*` variables that this
   image never reads; reproduced on their configuration, the container exits 1
   with `could not translate host name "db"`. This entrypoint bypasses the stock
   one, takes the database from `PG*`, and leaves `$PORT` as the HTTP port —
   which is also what a public Railway healthcheck dials.
4. **`proxy_mode = True` and a frozen `web.base.url`.** Railway terminates TLS,
   so without proxy mode Odoo builds every emailed link and password-reset URL
   from the container's own host.
5. **Non-root.** Railway mounts volumes uid 0 and the image runs as uid 100. The
   entrypoint chowns the mount and `setpriv`s down instead of running the whole
   ERP as root via `RAILWAY_RUN_UID=0`.
6. **Pinned by digest**, against an untagged `odoo` on one listing — Odoo major
   upgrades migrate one way.

`workers` deliberately stays at the upstream `0` (threaded mode): in prefork mode
Odoo serves the websocket bus from a second port, and Railway routes one port per
service, so `workers > 0` would silently kill live notifications.

## Environment

| Variable | Required | Notes |
|---|---|---|
| `ODOO_ADMIN_PASSWORD` | yes | administrator password, re-applied every boot |
| `ODOO_MASTER_PASSWORD` | yes | `admin_passwd`; the database manager stays disabled regardless |
| `ODOO_PGHOST` | yes | Postgres host |
| `ODOO_PGSUPERPASSWORD` | yes | superuser password, used once per boot to bootstrap the role |
| `ODOO_DB_PASSWORD` | yes | password for the dedicated `odoo` role |
| `ODOO_PGPORT` `ODOO_PGSUPERUSER` | baked | `5432`, `postgres` |
| `ODOO_DB_NAME` `ODOO_DB_USER` `ODOO_ADMIN_LOGIN` | baked | `odoo`, `odoo`, `admin` |
| `PORT` | injected | HTTP listen port |

Two Postgres traps this handles, both measured against the stock images:

- Odoo aborts on a `db_user` named `postgres` (*"Using the database user 'postgres'
  is a security risk, aborting."*), so pointing it straight at the stock Postgres
  service crash-loops. The entrypoint creates a dedicated `odoo` role and a
  database owned by it, idempotently, re-applying the password each boot.
- **Odoo's config layer reads the libpq environment and it overrides
  `odoo.conf`.** With `PGPASSWORD` set, `db_password` parsed out as the libpq
  value and the first boot died with `password authentication failed for user
  "odoo"` while the same credentials worked from `psql`. Hence the `ODOO_PG*`
  names, and an explicit `unset` of every `PG*` variable before Odoo runs.
