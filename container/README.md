# Local Dockerfile development & testing

This is for dev/test: verifying that `Dockerfile`/`configure.php` actually produce a
working Flyspray instance not for building production images. Production
images are built by AWS CodeBuild (see the root [README.md](../README.md) and
[terraform/build.tf](../terraform/build.tf)); nothing here is used by that
pipeline. If you are just deploying Flyspray to AWS you don't need to 
install Docker.  For one reason it can be difficult to build images
that need to run on X86 images on an ARM Mac. 

Dev Prerequisites: Docker Desktop (or compatible) with the `docker compose` v2
plugin. Everything runs locally; no AWS credentials are needed.

Run all commands from this `container/` directory.

## Option A: test against a blank database (verifies the install path)

This exercises the real Flyspray web installer, so it proves the image has
the right PHP extensions, dependencies, and file permissions to actually
install Flyspray from nothing — something the production image (which removes
`setup/`) cannot do, and which `configure.php` alone does not test.

```bash
docker compose -f docker-compose.dev.yml up --build
```

1. Open <http://localhost:8080/setup/> and complete the installer using:
   - Database type: PostgreSQL
   - Host: `db`, Port: `5432`, Database: `flyspray`
   - User: `flyspray_user`, Password: `dev-only-password`
   - Table prefix: `flyspray_`

   The installer always reports Flyspray is already configured (because
   `configure.php` already generated a config at container startup). To delete it:

   ```bash
   docker compose -f docker-compose.dev.yml exec app rm -f /var/www/html/flyspray.conf.php
   ```
   then reload.  It's a to-do item to do this inside the dockerfile. 

2. after the system is installed or 'setup' the system requires you to delete the 'setup' folder
   do this with 
   ```
   docker compose -f docker-compose.dev.yml exec app rm -rf /var/www/html/setup
   ```


3. After the installer finishes, restart the `app` container so
   `configure.php` regenerates `flyspray.conf.php` from the compose file's
   env vars (this is what production always does; it only sets the DB
   connection and a couple of general settings, so it doesn't undo the
   schema the installer just created):

   ```bash
   docker compose -f docker-compose.dev.yml restart app
   ```

3. Confirm the app loads at <http://localhost:8080/> and that you can log in
   as the admin account created during setup.

## Option B: test against an existing SQL dump (verifies the migration path)

This is closer to the real deployment: a database that already has Flyspray's
schema and data, with no installer involved — the same path `configure.php`
and the production image use.

1. Copy a **plain-SQL** dump (not a `pg_dump -Fc` custom-format dump) into
   `dev-dump/`, e.g. `dev-dump/dump.sql`. Files in `dev-dump/` are
   gitignored. It only runs on a first-time (empty) database volume, so
   remove any previous volume first:

   ```bash
   docker compose -f docker-compose.dev.yml down -v
   ```

2. Start the stack. Postgres's official image automatically runs any
   `*.sql`/`*.sh` file found in `dev-dump/` once, against the `flyspray`
   database, before `app` starts:

   ```bash
   docker compose -f docker-compose.dev.yml up --build
   ```

3. Confirm the app loads at <http://localhost:8080/> and that existing data
   (projects, tasks, logins) appears as expected.

## Cleanup

```bash
docker compose -f docker-compose.dev.yml down -v
```

`down -v` also removes the Postgres data volume, which is required before
re-testing Option A or loading a different dump in Option B.

## Notes

- `INCLUDE_SETUP=true` is passed only by `docker-compose.dev.yml`; the
  production build (CodeBuild, via `terraform/build.tf`) never sets it, so
  `setup/` is always removed from the deployed image.
- The dev cookie salt, passwords, and ports here are throwaway values for
  localhost only — never reuse them for a real deployment.
