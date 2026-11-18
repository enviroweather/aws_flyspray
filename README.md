# Flyspray on Lightsail Containers

Terraform manages a long-lived Lightsail container service, a Lightsail TLS
certificate, and a private Lightsail PostgreSQL database. The container runs
Flyspray with PHP and Apache. Lightsail operates the hosts; you still need to
rebuild, update, and scan the application and image regularly.

**This is a migration starting point, not yet a production-ready replacement.**
The image intentionally disables uploads and does not provide durable storage
for attachments or avatars. Existing files are not included. Containers and
their writable files can disappear at any restart or deployment. Preserve and
restore these separately, and implement/test durable storage before migrating
an installation that needs them. Sessions and cache are also ephemeral; use a
single node and expect sessions to be lost on redeployment. The static health
check tests Apache, not database or application health.

## DNS and lifecycle

Lightsail static IPs attach to instances, not container services. The existing
IP is retained in Terraform, but cannot direct traffic to the container. A
one-time GoDaddy change from the old A record to a CNAME is necessary, in
addition to a certificate-validation CNAME. The service's generated hostname
stays the same across image deployments and capacity changes **while that
service exists**. Deleting and recreating the service gives it a new hostname,
requiring another DNS change. Ordinary retries should redeploy an image, not
destroy the service.

The service, database, and legacy static IP have `prevent_destroy` guards.
Consequently `terraform destroy` will fail while these resources remain in the
configuration. The service is billable even when disabled or without a
deployment; the retained unattached static IP may also incur charges. Check
current prices with `aws lightsail get-container-service-powers --region REGION`
and the Lightsail pricing page.

## Security

Passwords and the base64-encoded Flyspray configuration are stored in
Terraform state and plan files and in the Lightsail deployment environment.
Base64 is not encryption, and `sensitive` only hides normal Terraform output.
Anyone allowed to read Lightsail deployments can read these values. Restrict
IAM and access to state, plans, shell environments, backups, and logs; use an
encrypted, versioned, locked remote backend for production. The existing local
backend is retained to avoid an implicit state migration. See
[Terraform's S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3)
and migrate state separately after backing it up. Do not print full deployment
specifications or commit credentials. Ensure the private database and container
are in the same Lightsail account and region, and verify connectivity.

## Prerequisites

- Terraform 1.5 or later, the locked AWS provider 5.x, and AWS CLI v2. **No
  local Docker install is required** — images are built by AWS CodeBuild on an
  AWS-managed x86_64 host, so an Apple Silicon (or any ARM) workstation never
  has to cross-compile, and colleagues don't need Docker installed at all.
- AWS credentials with permissions for Lightsail, ECR, CodeBuild, S3, and IAM
  (to create the CodeBuild service role). Terraform provisions the ECR repo,
  the S3 bucket CodeBuild reads its source from, the CodeBuild project, and an
  ECR repository policy that lets the Lightsail service pull images directly
  (no `lightsailctl`/`push-container-image` step).
- Terraform provisions the managed Lightsail PostgreSQL *server* itself
  (`aws_lightsail_database.flyspray` in [terraform/main.tf](terraform/main.tf))
  — there's nothing to pre-provision there. What this workflow assumes you
  already have is the **existing Flyspray application data**: a SQL dump of
  the current database, because
  [terraform/scripts/import_db.sh](terraform/scripts/import_db.sh) creates the
  `app_db`/`app_user` role and database and imports that dump, rather than
  running Flyspray's own schema installer (the image removes
  `/var/www/html/setup` for security). See [Database import](#database-import).
  A brand-new, schema-less Flyspray install (no prior data to migrate) is not
  yet supported by this image.
- Flyspray itself has no native environment-variable support (verified against
  upstream source): [container/configure.php](container/configure.php) runs
  once at container startup and writes `flyspray.conf.php` from plain
  environment variables (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`,
  `DB_PREFIX`, `COOKIE_SALT`, `APP_BASE_URL`, `SYNTAX_PLUGIN`) that Terraform
  sets directly on the Lightsail deployment from `.env`/`TF_VAR_*` values — no
  secret is baked into the image, and no base64-encoded config blob is needed.
  If migrating an existing install, reuse its `dbprefix` and `cookiesalt`
  values so existing data and sessions remain valid.
- A Flyspray release compatible with the existing database schema and PHP.
  The Dockerfile defaults to upstream `1.0-rc11`. Check compatibility and
  upgrades before cutover. Choose another release by setting `flyspray_version`
  in Terraform. An upgrade may require a separate Flyspray upgrade procedure;
  the image removes the public setup directory and does not run schema
  upgrades.

## Migration

Run Terraform commands from `terraform/`. Do not run a normal full apply until
the container has been verified and you are ready to remove the old VM. These
steps intentionally use targeted plans during the transition; targeting is an
exception, so inspect each plan and run a full plan at the end.

1. Back up the database, the existing Flyspray configuration, attachments,
   avatars, and Terraform state to a protected location. Verify the backups can
   be restored. Record the current A record, static IP, region, account, and
   VM details. Avoid concurrent state operations. Do not import a dump into an
   existing database merely to move compute: the container can use the current
   private database and application user.

2. Review the existing `terraform.tfvars`, especially region, `instance_name`,
   database settings, app user, and hostname. Keep the existing instance name
   so the legacy IP name does not change. For a new environment start from
   [terraform/terraform.tfvars.example.txt](terraform/terraform.tfvars.example.txt).
   Leave `deploy_flyspray` at its default `false` and `enable_custom_domain`
   false for the initial stage. Copy [example.env.txt](example.env.txt) to the
   ignored root `.env`, and export `TF_VAR_db_master_password`,
   `TF_VAR_app_password`, and `TF_VAR_cookie_salt` there without shell history.
   Also set the resource-provenance values there: `created_by` is evaluated
   from the current OS user (`$USER`, falling back to `$USERNAME`) whenever the
   file is sourced, and `build_ver` is a one-time UTC timestamp generated with
   `date -u '+%Y-%m-%dT%H:%M:%SZ'`. Replace `build_ver` only when intentionally
   starting a distinct deployment; never use Terraform's `timestamp()` for it,
   because that would change tags on every plan/apply. The application password
   must match the existing database role; Terraform does not change that role.

   ```bash
   cp example.env.txt .env
   # Edit .env: replace secrets and the build_ver placeholder.
   set -a
   source .env
   set +a
   ```

3. Initialize and create the service, certificate, ECR repository, and
   CodeBuild project. Review the saved plan before applying it. If Terraform
   proposes an unexpected deletion or replacement, stop. The initial service
   has no application deployment and still incurs charges.

   ```bash
   cd terraform
   terraform init
   terraform plan -target=aws_lightsail_container_service.flyspray \
     -target=aws_lightsail_certificate.flyspray \
     -target=aws_codebuild_project.flyspray -out=service.tfplan
   terraform show service.tfplan
   terraform apply service.tfplan
   terraform output container_url
   terraform output certificate_validation_records
   ```

4. Add the certificate validation record shown in the output at GoDaddy. Leave
   the existing traffic A record in place for now. Wait until the Lightsail
   certificate status is `ISSUED`, checking in the Lightsail console or with:

   ```bash
   aws lightsail get-certificates --region "$(terraform output -raw region)" \
     --query 'certificates[].{name:certificateName,status:certificateDetail.status}'
   ```

   Keep the validation CNAME for renewal. GoDaddy may append the zone name to a
   record's host field; avoid entering the domain twice.

5. Trigger CodeBuild to build and push the image. This runs entirely in AWS
   on an x86_64 host — no Docker or `lightsailctl` is installed or used
   locally, so any colleague with Terraform and AWS CLI access can run it.

   ```bash
   bash scripts/start_build.sh
   ```

   To build a different compatible Flyspray release, set `flyspray_version`
   in Terraform first (it's passed to CodeBuild as a build argument) and
   re-apply the CodeBuild project before re-running the script.

6. Prepare the deployment. Set `deploy_flyspray` to `true` (`cookie_salt` must
   already be exported, per step 2). Terraform resolves the current digest for
   `image_tag` (default `latest`) via a data source, so re-running this same
   plan after any future CodeBuild push automatically picks up the new image
   — no image tag or reference needs to be copied by hand. The deployment's
   `DB_PREFIX` defaults to `flyspray_`; override it in tfvars if the existing
   database uses a different prefix. The target keeps the old VM in place;
   review the plan for database replacement or other changes.

   ```bash
   export TF_VAR_deploy_flyspray=true
   export TF_VAR_enable_custom_domain=true
   terraform plan -target=aws_lightsail_container_service_deployment_version.flyspray \
     -out=deployment.tfplan
   terraform show deployment.tfplan
   terraform apply deployment.tfplan
   ```

   Passwords, the cookie salt, and the saved plan are sensitive. Terraform may
   show changes involving secrets in plans and state; handle both accordingly.
   Check status and logs without printing deployment environment values:

   ```bash
   aws lightsail get-container-service-deployments --region "$(terraform output -raw region)" \
     --service-name "$(terraform output -raw container_service_name)" \
     --query 'deployments[].{version:version,state:state}'
   aws lightsail get-container-log --region "$(terraform output -raw region)" \
     --service-name "$(terraform output -raw container_service_name)" --container-name flyspray
   ```

7. Once the deployment is active and the certificate is attached, replace the
   GoDaddy A record for the app hostname with a CNAME to the **hostname** in
   `terraform output -raw container_url` (no `https://` or trailing path). DNS
   changes take time. Verify HTTPS, login, database access, links, and the
   limitations on files and sessions. The default service URL is useful for
   the static `/health.txt` check; the application forces the custom hostname.

8. Only after verifying the cutover and backups, run an untargeted plan. It
   should propose removing the old VM, attachment, firewall, snapshot helper,
   and generated VM files. It must not replace or destroy the database, static
   IP, or service. Review and approve the saved plan before applying:

   ```bash
   terraform plan -out=cutover.tfplan
   terraform show cutover.tfplan
   terraform apply cutover.tfplan
   ```

   Delete old sensitive plan files securely according to your organization's
   process. Do not run the old `output/setup_ssl.sh`; Lightsail handles TLS.

## Rollback and recovery

Before removing the VM, rollback means restoring the original GoDaddy A record
to the retained static IP and leaving the old instance attached. DNS propagation
can delay rollback. After the VM is removed, an IP alone cannot serve traffic:
restore an instance from a verified snapshot or backup and attach the IP, then
restore DNS. A rollback of a container image can re-tag a previously pushed ECR
image as `image_tag` (or add a dedicated `image_tag` variable value pinned to
an older digest) and apply a reviewed Terraform plan. Protect database and
file backups independently of the VM and container service.

To intentionally remove protected resources, first take and verify backups,
review current state and billing, explicitly remove the relevant lifecycle
guard in configuration, then run `terraform plan -destroy` and inspect every
resource before approving `terraform destroy`. Destroying the service changes
the hostname on recreation; destroying the IP releases it. The database is
configured to skip a final snapshot, so create and verify one separately before
any intentional database deletion.

## Database import

The existing database does not need reimporting during a compute-only migration.
For a **new, empty** database, [terraform/scripts/import_db.sh](terraform/scripts/import_db.sh)
imports a plain SQL dump from the configured S3 location. It refuses to import
if public tables already exist and stops on SQL errors. It requires `psql`,
AWS CLI, exported password variables, and network access to the private DB.
It never changes public accessibility. Run on a trusted host with private
network connectivity, or establish an SSH tunnel through an appropriately
secured existing host and set `PGHOST` and `PGPORT`. Restrict access to temporary
files and verify the imported schema, credentials, and permissions afterwards.
The script does not reset the password of an existing role. Custom-format dumps
require a separately planned `pg_restore` workflow.

To upload a plain SQL dump to an existing private bucket, run from the project
root `bash upload_dump_to_s3.sh /secure/path/dump.sql BUCKET KEY`, then set
`s3_bucket` and `s3_dump_key` in Terraform and apply a reviewed plan. The
upload overwrites an existing object with the same key; use a unique key or
bucket versioning. Restrict access to the bucket and its backups.

## Files

- [terraform/main.tf](terraform/main.tf): retained IP and managed database.
- [terraform/container.tf](terraform/container.tf): service, certificate, and deployment.
- [terraform/build.tf](terraform/build.tf): ECR repository, S3 build source, and CodeBuild project.
- [terraform/scripts/start_build.sh](terraform/scripts/start_build.sh): triggers and waits on a CodeBuild run.
- [container/Dockerfile](container/Dockerfile): PHP/Apache image.
- [container/configure.php](container/configure.php): runtime configuration.
- [container/README.md](container/README.md): local Docker dev/test instructions (not used by CodeBuild).
- [notes-docker.md](notes-docker.md): historical AI proposal, not instructions.