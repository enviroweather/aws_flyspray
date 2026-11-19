# Notes on building flyspray instance on AWS lightsail

## Rebuilding the container after changes

when rebuilding, It turns out you can't just 
`export TF_VAR_deploy_flyspray=true`   sets the variable as a string "true" but Terraform's type system is strict — your variable is declared as type = bool, so it needs an actual boolean. It needs to be set in tfvars or pass -var="deploy_flyspray=true" on the command line

```
 terraform apply \                                                                                                               
  -var="deploy_flyspray=true" \
  -var="enable_custom_domain=true" \
  -var="cookie_salt="<valueorenvironmentvar>"
```



check if the S3 build source contains the current `container` contents or must be refreshed with Terraform before `start_build.sh`.

Ran terminal command:  set -a; source .env; set +a; terraform -chdir=terraform state list; printf '\n--- current build object ---\n'; terraform -chdir=terraform state show 'aws_s3_object.container_source' | sed -n '1,30p'; printf '\n--- current codebuild project ---\n'; terraform -chdir=terraform state show 'aws_codebuild_project.flyspray' | grep -E '^\s+(name|source|location|buildspec|value|INCLUDE_SETUP)' | head -40

Read 

Read 

Read , lines 100 to 161

Ran terminal command:  set -a; source .env; set +a; terraform -chdir=terraform plan -out=rebuild.tfplan -target=aws_s3_object.container_source -target=aws_codebuild_project.flyspray

One critical prerequisite surfaced: the build archive currently includes the whole `container` folder, including `dev-dump/import.sql` and `orig.db.sql.txt`. They are not copied into the final image, but they would be uploaded to S3 and sent to CodeBuild. I’ll exclude database dumps from that build archive first, then regenerate the safe targeted plan.






````

````


Ran terminal command:  terraform -chdir=terraform fmt -check terraform 2>/dev/null || terraform fmt terraform/build.tf; terraform -chdir=terraform validate && set -a; source .env; set +a; terraform -chdir=terraform plan -out=rebuild.tfplan -target=aws_s3_object.container_source -target=aws_codebuild_project.flyspray

Ran terminal command:  bash tests/test-configure.sh && php -l container/configure.php && bash -n terraform/scripts/start_build.sh && terraform -chdir=terraform validate && git diff --check -- container terraform/build.tf

The rebuild needs **two stages**: upload the current container source, then build it.

## 1. Refresh CodeBuild source and configuration

I prepared and validated:

```bash
cd terraform
terraform show rebuild.tfplan
terraform apply rebuild.tfplan
```

This changes only:

- S3 build ZIP from the current `container`
- CodeBuild source location/build arguments
- `INCLUDE_SETUP=false`

It does not deploy Lightsail, alter the database, or restart the app.


## 2. Build and push to ECR

```bash
bash scripts/start_build.sh
```

This pushes the newly built digest to the existing `latest` tag.

## 3. Deploy that new digest to Lightsail

A successful CodeBuild alone does **not** update the running container.

From `terraform`:

```bash
set -a
source ../.env
set +a

export TF_VAR_deploy_flyspray=true

terraform plan \
  -target=aws_lightsail_container_service_deployment_version.flyspray \
  -out=deployment.tfplan

terraform show deployment.tfplan
terraform apply deployment.tfplan
```

Confirm the deployment becomes active, then test:

```bash
curl -I https://flyspray.enviroweather.net/health.txt
```

The plan should replace/update only the Lightsail deployment version and pin the new ECR digest. Review it before applying.

**Important:** The production container deployment also runs `configure.php` at every startup, but the database now holds the migrated schema and repaired search data separately. The image rebuild fixes application/config code; it does not replace the database.

Assumptions: Terraform 1.17, AWS provider 5.x, existing local state. Validation passed, and nothing has been applied or deployed by this response.

Made changes.


### oh the db upgrade pain: passwords and searches

Needed to clear out/reset everyone fs passwords.  

Once the local docker compose db is up and running (and db imported from the dev-dump folder),
run this new script container/scripts/reset_local_passwords.sh to put new passwords in the db
and documnnt those new passwords. 

there are also problems with some wonky search paths in the db no longer compatible, so once 
logged in, the page was just blank - cleared those out of the db

the new list of passwords and new db dump are saved on Sharepoint (general/it management/flyspray)

----

#### MAI code 2 session to figure this out and fix it

I’ll distinguish a blank authenticated page from missing project/group permissions versus migrated serialized searches breaking the template. We already saw an `unserialize()` notice in `links.searches.tpl`; I’ll inspect the project membership, task counts, rendered HTML, and the legacy serialized fields.

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -P pager=off -c "SELECT p.project_id,p.project_title,p.project_is_active FROM flyspray_projects p ORDER BY p.project_id;" -c "SELECT project_id,count(*) AS task_count,min(task_id) AS first_task,max(task_id) AS last_task FROM flyspray_tasks GROUP BY project_id ORDER BY project_id;" -c "SELECT uig.user_id,u.user_name,uig.group_id,g.group_name,g.project_id,g.group_open FROM flyspray_users_in_groups uig JOIN flyspray_users u USING(user_id) JOIN flyspray_groups g USING(group_id) WHERE u.user_name='brownja' ORDER BY g.project_id,g.group_id;"

Ran terminal command:  cred_file=/Users/billspat/Code/enviroweather-project/new_flyspray_passwords.txt; tmp_password=$(grep '^2,brownja,' "$cred_file" | head -1 | cut -d, -f3); rm -f /tmp/flyspray-auth-cookies.txt /tmp/flyspray-stations.html; curl -fsS -c /tmp/flyspray-auth-cookies.txt -b /tmp/flyspray-auth-cookies.txt -o /dev/null http://localhost:8080/; curl -fsSL -c /tmp/flyspray-auth-cookies.txt -b /tmp/flyspray-auth-cookies.txt -o /tmp/flyspray-stations.html --data-urlencode 'user_name=brownja' --data-urlencode "password=$tmp_password" --data-urlencode 'return_to=/' 'http://localhost:8080/index.php?do=authenticate'; printf 'HTML bytes: '; wc -c < /tmp/flyspray-stations.html; printf '\nWarnings/fatals/notices:\n'; grep -oiE '(Warning|Notice|Fatal error):[^<]+' /tmp/flyspray-stations.html | head -30; printf '\nProject/task excerpts:\n'; grep -oiE 'Stations|No tasks found|[0-9]+ tasks?|task_id[^>]*' /tmp/flyspray-stations.html | head -40; unset tmp_password

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T app sh -c 'nl -ba /var/www/html/themes/CleanFS/templates/links.searches.tpl | sed -n "1,80p"; nl -ba /var/www/html/includes/class.tpl.php | grep -n -B3 -A8 "unserialize" | head -80'

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -P pager=off -c "SELECT search_id,user_id,project_id,name,octet_length(search_string) AS bytes,left(search_string,40) AS preview FROM flyspray_searches ORDER BY search_id;" -c "SELECT column_name,data_type,character_maximum_length FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('flyspray_tasks','flyspray_searches') ORDER BY table_name,ordinal_position;"

The data is present: `Stations` has 3,768 tasks, and `brownja` is a project-manager member. The blank appearance is not missing issues. The authenticated page is rendering only partway through because legacy saved-search serialization is invalid under modern PHP/Flyspray; I’ll inspect the page cutoff and the saved-search payload, then safely clear only broken saved-search rows in the disposable Compose database.

Ran terminal command:  printf '%s\n' '--- page tail ---'; nl -ba /tmp/flyspray-stations.html | tail -100; printf '%s\n' '--- task controls/content ---'; grep -nEi 'tasklist|item_summary|projectselector|content|showtask|Stations|nosearches|Error at offset' /tmp/flyspray-stations.html | head -100

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -P pager=off -c "SELECT id,user_id,name,octet_length(search_string) AS bytes,left(search_string,80) AS preview FROM flyspray_searches ORDER BY id;" -c "SELECT u.user_name,s.id,s.name FROM flyspray_searches s JOIN flyspray_users u USING(user_id) ORDER BY u.user_name,s.id;"

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T app sh -c 'grep -Rni "new Flyspray\|search_string\|INSERT INTO.*searches\|unserialize(.*search" /var/www/html/includes /var/www/html/scripts 2>/dev/null | head -120'

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -At -F '|' -c "SELECT id,user_id,encode(convert_to(search_string,'UTF8'),'base64') FROM flyspray_searches ORDER BY id;" | php -r '$validRaw=$validStripped=$invalid=0; while(($line=fgets(STDIN))!==false){[$id,$uid,$b64]=explode("|",rtrim($line,"\n"),3); $s=base64_decode($b64); $raw=@unserialize($s); $fixed=@unserialize(stripslashes($s)); if(is_array($raw)){$validRaw++;} elseif(is_array($fixed)){$validStripped++; echo "id=$id user=$uid repaired_by_stripslashes\n";} else {$invalid++; echo "id=$id user=$uid still_invalid\n";}} echo "raw_valid=$validRaw stripslashes_valid=$validStripped invalid=$invalid\n";'

Read , lines 1 to 80

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -q -c "COPY (SELECT id,user_id,encode(convert_to(search_string,'UTF8'),'base64') FROM flyspray_searches ORDER BY id) TO STDOUT WITH (FORMAT csv)" | php -r '$raw=0;$fixed=0;$invalid=0; while(($line=fgets(STDIN))!==false){$cols=str_getcsv(rtrim($line,"\r\n")); if(count($cols)!==3)continue; [$id,$uid,$b64]=$cols; $s=base64_decode($b64); if(is_array(@unserialize($s))){$raw++;} elseif(is_array(@unserialize(stripslashes($s)))){$fixed++; echo "id=$id user=$uid repaired_by_stripslashes\n";} else {$invalid++; echo "id=$id user=$uid still_invalid\n";}} echo "raw_valid=$raw stripslashes_valid=$fixed invalid=$invalid\n";'

No matches found.

Searched for regex `wrap|still_invalid|raw_valid` (`**/*.txt`), 9 results

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -P pager=off -c "SELECT position((chr(92) || chr(34)) IN search_string)>0 AS legacy_backslash_escaping,count(*) FROM flyspray_searches GROUP BY 1 ORDER BY 1;" -c "SELECT id,user_id,name FROM flyspray_searches WHERE position((chr(92) || chr(34)) IN search_string)>0 ORDER BY id;"

Ran terminal command:  cred_file=/Users/billspat/Code/enviroweather-project/new_flyspray_passwords.txt; password=$(grep '^2,brownja,' "$cred_file" | head -1 | cut -d, -f3); rm -f /tmp/flyspray-auth-cookies.txt; curl -fsS -c /tmp/flyspray-auth-cookies.txt -b /tmp/flyspray-auth-cookies.txt -o /dev/null http://localhost:8080/; curl -fsS -c /tmp/flyspray-auth-cookies.txt -b /tmp/flyspray-auth-cookies.txt -o /dev/null --data-urlencode 'user_name=brownja' --data-urlencode "password=$password" --data-urlencode 'return_to=/' http://localhost:8080/index.php?do=authenticate; for url in 'http://localhost:8080/' 'http://localhost:8080/?project=2'; do printf '%s -> ' "$url"; curl -sS -b /tmp/flyspray-auth-cookies.txt -o /tmp/flyspray-page.html -w 'HTTP %{http_code}, %{size_download} bytes\n' "$url"; done; unset password

The saved-search rows—not task rows—are causing the page to abort. Twelve legacy rows contain backslash-escaped serialized PHP strings; rc11 calls `unserialize()` and then passes the failure (`false`) to `http_build_query()`, which throws before the task list renders. I’ll first prove all 12 are repairable by removing only quote escapes in a rollback-only test, leaving 11 valid searches unchanged.

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -P pager=off -At -c "SELECT encode(convert_to(replace(search_string, chr(92) || chr(34), chr(34)),'UTF8'),'base64') FROM flyspray_searches WHERE id IN (1,2);" | while IFS= read -r encoded; do [[ -z "$encoded" ]] && continue; printf '%s' "$encoded" | base64 -d | php -r '$s=stream_get_contents(STDIN); echo is_array(@unserialize($s)) ? "valid serialized array\n" : "still invalid\n";'; done

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T app php -r '$pdo=new PDO("pgsql:host=db;dbname=flyspray", "flyspray_user", "dev-only-password"); $stmt=$pdo->query("SELECT id, search_string FROM flyspray_searches ORDER BY id"); $raw=$fixed=$invalid=0; foreach($stmt as $r){$s=$r["search_string"]; if(is_array(@unserialize($s))){$raw++; continue;} $s2=str_replace(chr(92).chr(34),chr(34),$s); if(is_array(@unserialize($s2))){$fixed++; echo "id={$r["id"]} repaired_by_quote_unescape\n";} else {$invalid++; echo "id={$r["id"]} still_invalid\n";}} echo "raw_valid=$raw repaired=$fixed invalid=$invalid\n";'

All 23 saved searches are accounted for: 11 already deserialize correctly, and the 12 legacy rows become valid with one narrow transformation—removing backslashes before quotes. I’ll apply that migration only to the local Compose database, then retest the Stations task page and ensure the fatal exception disappears.

Ran terminal command:  docker compose -f container/docker-compose.dev.yml exec -T db psql -U flyspray_user -d flyspray -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
UPDATE flyspray_searches
SET search_string = replace(search_string, chr(92) || chr(34), chr(34))
WHERE position((chr(92) || chr(34)) IN search_string) > 0;
COMMIT;
SQL
cred_file=/Users/billspat/Code/enviroweather-project/new_flyspray_passwords.txt; password=$(grep '^2,brownja,' "$cred_file" | head -1 | cut -d, -f3); rm -f /tmp/flyspray-auth-cookies.txt /tmp/flyspray-stations-fixed.html; curl -fsS -c /tmp/flyspray-auth-cookies.txt -b /tmp/flyspray-auth-cookies.txt -o /dev/null 'http://localhost:8080/'; curl -fsSL -c /tmp/flyspray-auth-cookies.txt -b /tmp/flyspray-auth-cookies.txt -o /tmp/flyspray-stations-fixed.html --data-urlencode 'user_name=brownja' --data-urlencode "password=$password" --data-urlencode 'return_to=/?project=2' 'http://localhost:8080/index.php?do=authenticate'; unset password; http_bytes=$(wc -c < /tmp/flyspray-stations-fixed.html | tr -d ' '); printf 'Rendered bytes: %s\n' "$http_bytes"; if grep -qE 'Unhandled exception|Error at offset|Fatal error' /tmp/flyspray-stations-fixed.html; then echo 'Render error remains' >&2; exit 1; fi; grep -q 'Stations' /tmp/flyspray-stations-fixed.html && echo 'Stations page rendered'; grep -qE 'task_id=[0-9]+|item_summary|tasklist_table' /tmp/flyspray-stations-fixed.html && echo 'Task list controls/content rendered' || echo 'Task list markers not found; inspect filters/result count'; grep -oiE 'Showing[^<]*|No tasks[^<]*|[0-9]+ results?' /tmp/flyspray-stations-fixed.html | head -20

The issues exist, and the page is now fixed locally.

Cause:

- `Stations` contains **3,768 tasks**
- Twelve legacy saved-search rows used backslash-escaped PHP serialization.
- PHP 8.2 could not deserialize one row and aborted rendering before the task list.

Applied locally:

- Repaired 12 saved-search records.
- Left 11 already-valid searches unchanged.
- No task/project/user data was deleted.

Verification:

- Stations page rendered successfully.
- No `unserialize` or unhandled exception.
- Task list displayed: **tasks 1–25 of 935 matching tasks**.

==========================

The local Compose database now contains the fixes and password resets. 
**Export this final version before replacing Lightsail:**

```bash
cd container

docker compose -f docker-compose.dev.yml exec -T db \
  pg_dump -U flyspray_user -d flyspray \
  --format=plain --no-owner --no-privileges \
  > ~/Downloads/flyspray-final-migrated.sql
```
=========


Treat that as the authoritative migration dump. It includes the upgraded schema, bcrypt password resets, and saved-search repair. Keep the generated password list private, distribute it, and then delete it securely.


---
#### updating the 'prod' db on AWS Lightsail

we need to take our updated db and get it on AWS.  

I’ll verify the current import script before giving the cutover sequence, because it should remain the guarded restore path after the database is dropped.

Read 

Recommended approach: **rename the current database instead of dropping it**, import into a fresh database, verify, and retain the renamed database for rollback.

Run from `terraform`:

```bash
set -a
source ../.env
set +a

DB_HOST=$(terraform output -raw db_endpoint)
DB_PORT=$(terraform output -raw db_port)
APP_DB=$(terraform output -raw app_db)
BACKUP_DB="${APP_DB}_before_final_20261118"
```

## 1. Back up the current Lightsail database

```bash
PGPASSWORD="$TF_VAR_db_master_password" pg_dump \
  -X \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U dbmaster \
  -d "$APP_DB" \
  --format=custom \
  --no-owner \
  --no-privileges \
  > "$HOME/Downloads/lightsail-before-final.dump"
```

Verify it was created:

```bash
ls -lh "$HOME/Downloads/lightsail-before-final.dump"
pg_restore -l "$HOME/Downloads/lightsail-before-final.dump" | head
```

## 2. Rename the current database

This forces a clean import target while preserving the old database:

```bash
PGPASSWORD="$TF_VAR_db_master_password" psql \
  -X \
  -v ON_ERROR_STOP=1 \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U dbmaster \
  -d postgres \
  -v app_db="$APP_DB" \
  -v backup_db="$BACKUP_DB" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'app_db'
  AND pid <> pg_backend_pid();

SELECT format(
  'ALTER DATABASE %I RENAME TO %I',
  :'app_db',
  :'backup_db'
) \gexec
SQL
```

The application may be unavailable briefly after this command.

## 3. Import the new local dump

```bash
bash scripts/import_db.sh \
  "$HOME/Downloads/flyspray-final-migrated.sql"
```

The script:

- Creates the fresh application database.
- Restores the dump in one transaction.
- Refuses to import if public tables already exist.
- Grants required privileges to the application role.

## 4. Verify the migrated database

```bash
PGPASSWORD="$TF_VAR_app_password" psql \
  -X \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$(terraform output -raw app_user)" \
  -d "$APP_DB" \
  -v ON_ERROR_STOP=1 \
  -c "SELECT pref_value AS flyspray_version
      FROM flyspray_prefs WHERE pref_name='fs_ver';" \
  -c "SELECT count(*) AS station_tasks
      FROM flyspray_tasks WHERE project_id=2;" \
  -c "SELECT count(*) AS users FROM flyspray_users;" \
  -c "SELECT count(*) AS saved_searches FROM flyspray_searches;"
```

Expected:

```text
flyspray_version = 1.0-rc11
station_tasks     = 3768
users             = 7
saved_searches    = 23
```

Then test:

```bash
curl -I https://flyspray.enviroweather.net/health.txt
```

and log in using a temporary credential from the private password file.

## Rollback if import or verification fails

```bash
PGPASSWORD="$TF_VAR_db_master_password" psql \
  -X \
  -v ON_ERROR_STOP=1 \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U dbmaster \
  -d postgres \
  -v app_db="$APP_DB" \
  -v backup_db="$BACKUP_DB" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'app_db'
  AND pid <> pg_backend_pid();

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'backup_db'
  AND pid <> pg_backend_pid();

SELECT format('DROP DATABASE %I', :'app_db') \gexec
SELECT format('ALTER DATABASE %I RENAME TO %I',
              :'backup_db', :'app_db') \gexec
SQL
```

Do not delete the renamed database until the new Lightsail version has been verified.

**Assumption/risk:** Terraform local workflow, production-critical data cutover; the main risks are downtime and accidental data loss. No commands above should be run without verifying the dump and backup. State is not changed by these steps.


### 11/18 stuck in upgrade hell

the db dump we have is from an old version and it needs to be 'upgraded' to work withthe 
current version of flyspray.   The prod version of flyspray has the setup folder (and upgrade script)
removed to keep it safe, but the db sql needs upgrading!  solution: use our local docker compose version

Here are the instructions

That is a sound one-time migration strategy and is safer than exposing `/setup/upgrade.php` on the public Lightsail container. I’ll verify the Compose database settings and then outline the exact upgrade/export/re-import sequence, including the important backup/reset and version checks.

Read 

Read 

Read 

Yes. The local Compose database can be used as a disposable migration workstation, then production remains on a normal setup-free image. You do **not** need to enter local database settings into Flyspray because `configure.php` supplies them; the only local setup action needed should be the version upgrade itself.

Ran terminal command:  if [[ -f "$HOME/Downloads/flyspray_22_10_2026.sql" ]]; then printf '%s\n' '--- dump header ---'; sed -n '1,45p' "$HOME/Downloads/flyspray_22_10_2026.sql"; printf '%s\n' '--- database/role directives ---'; grep -nE '^(CREATE DATABASE|CREATE ROLE|ALTER (DATABASE|SCHEMA|TABLE|SEQUENCE|FUNCTION)|\\connect|\\c )' "$HOME/Downloads/flyspray_22_10_2026.sql" | head -40; else echo 'Dump not found'; fi

Yes—this is the safer one-time approach. It avoids exposing the upgrade interface publicly and requires no production rebuild afterward, because the current production image already generates `flyspray.conf.php` correctly at startup.

The redirect is caused by:

```text
Database fs_ver: 1.0-rc3
Image version:   1.0-rc11
```

Not by a missing configuration file.

## 1. Start with a completely fresh local database

From `container`:

```bash
mkdir -p dev-dump
cp ~/Downloads/flyspray_22_10_2026.sql dev-dump/import.sql

docker compose -f docker-compose.dev.yml down -v
docker compose -f docker-compose.dev.yml up --build
```

The Postgres container will import the dump once. Keep that terminal running for logs.

Important: `down -v` deletes the local Compose database—not Lightsail.

## 2. Run the Flyspray upgrade locally

Open:

```text
http://localhost:8080/setup/upgrade.php
```

Follow the upgrade workflow. The database connection is already configured:

```text
Host:     db
Port:     5432
Database: flyspray
User:     flyspray_user
Password: dev-only-password
Prefix:   flyspray_
```

You should not need to recreate `flyspray.conf.php`; the entrypoint generates it from Compose environment variables.

After upgrading, confirm that the normal application loads:

```text
http://localhost:8080/
```

Test a login and representative tasks.

## 3. Verify the schema version

Run:

```bash
docker compose -f docker-compose.dev.yml exec -T db \
  psql -U flyspray_user -d flyspray \
  -c "SELECT pref_value FROM flyspray_prefs WHERE pref_name='fs_ver';"
```

It should report:

```text
1.0-rc11
```

Also check application access:

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  http://localhost:8080/
```

## 4. Export the upgraded database

Create a portable plain-SQL dump:

```bash
docker compose -f docker-compose.dev.yml exec -T db \
  pg_dump -U flyspray_user -d flyspray \
  --format=plain \
  --no-owner \
  --no-privileges \
  --clean \
  --if-exists \
  > ~/Downloads/flyspray_1.0-rc11_upgraded.sql
```

`--clean` means the dump contains statements to remove old objects before recreating them. `--no-owner` avoids requiring local Compose roles in Lightsail.

Verify that the file is nonempty:

```bash
ls -lh ~/Downloads/flyspray_1.0-rc11_upgraded.sql
head -20 ~/Downloads/flyspray_1.0-rc11_upgraded.sql
```

## 5. Back up Lightsail before replacing anything

Because `--clean` replaces database objects, first take a backup of the current Lightsail database. Verify the backup exists and keep the original dump too.

The normal `scripts/import_db.sh` refuses to import into a nonempty database. Do not bypass that protection casually.

For this one-time operation, the safest options are:

1. Drop and recreate the empty Flyspray application database after taking a backup, then use the existing script; or
2. Use the `--clean` dump in a single PostgreSQL transaction after stopping/isolating application traffic.

Do not simultaneously let requests modify the old database during replacement.

## 6. Restore into Lightsail

After reviewing the backup and replacing/emptying the target database, run from `terraform`:

```bash
source ../.env
bash scripts/import_db.sh \
  ~/Downloads/flyspray_1.0-rc11_upgraded.sql
```

Then verify:

```sql
SELECT pref_value
FROM flyspray_prefs
WHERE pref_name = 'fs_ver';
```

Expected: `1.0-rc11`.

Because Flyspray’s upgrade altered the database, the live container should stop redirecting after the restore. A container restart will refresh its runtime state, but a rebuild is not necessary unless container application code actually changed.

## Important production detail

The Lightsail objects imported by `import_db.sh` are owned by `dbmaster`, while the application role has runtime privileges. That is fine for normal operation, but the application role should not perform future schema upgrades against tables it does not own. Use the master role or continue performing upgrades in local Compose.

After success:

```bash
docker compose -f docker-compose.dev.yml down -v
```

The production Dockerfile should remain at `INCLUDE_SETUP=false`, keeping `/setup` removed.



### 11/17 2pm

All checks pass. Summary of the redesign addressing your corrections:

No local Docker — build.tf adds an ECR repo, an S3 bucket holding a zipped container source (via archive_file, no Docker needed to prepare it), an IAM role, and an aws_codebuild_project. CodeBuild's standard:7.0 Linux image runs natively on x86_64, so a plain docker build inside CodeBuild produces a correct AMD64 image — no --platform flag, buildx, or local Docker install needed anywhere. Trigger it with start_build.sh, which only needs terraform + aws CLI.

Lightsail pulls straight from ECR — container.tf now sets private_registry_access { ecr_image_puller_role } on the service and grants that role pull access via aws_ecr_repository_policy, so there's no push-container-image/lightsailctl step at all.

Simplified secrets — removed flyspray_config_base64 entirely. configure.php now builds flyspray.conf.php from discrete env vars: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS, DB_PREFIX, COOKIE_SALT, APP_BASE_URL, SYNTAX_PLUGIN. Terraform sets these on the Lightsail deployment from TF_VAR_* values (your existing .env mechanism) — no secrets baked into the image.

Answering your question directly: yes — Flyspray has no native env-var support (confirmed from its source), but the configure.php entrypoint shim generates its config file from env vars at container startup, so DB credentials can be set as plain Lightsail environment variables sourced from .env.

Updated variables.tf, outputs.tf, tests, terraform.tfvars/.example.txt, example.env.txt, .gitignore, and README accordingly. All validated: terraform validate/fmt/test (3/3 pass), php -l, and the bash config test pass. No real apply has been run — the next step is a real AWS apply starting with the service/certificate/CodeBuild stage.

### 11/16 11pm 

add this to prevent IP address from being destroyed:

```
resource "aws_lightsail_static_ip" "flyspray" {
  name = local.static_ip_name

  lifecycle {
    prevent_destroy = true
  }
}

```

How can you destroy all the things, but keep the ip address?

**Step 1 — Detach the static IP first (before destroying the instance)**
terraform destroy \
  -target=aws_lightsail_static_ip_attachment.flyspray

**Step 2 — Destroy the instance, database, and dependent resources (NOT the static IP)**

terraform destroy \
  -target=null_resource.instance_auto_snapshot \
  -target=aws_lightsail_instance_public_ports.flyspray \
  -target=aws_lightsail_instance.flyspray \
  -target=aws_lightsail_database.flyspray

## 11/16 10pm switching away from bitnaming to an AWS blueprint

Important: SELinux Note

The lamp_ls_1_0
blueprint runs Amazon Linux 2023, which has SELinux enforcing by default. Without the setsebool
and chcon
commands in step 8, Apache will silently fail to write to the attachments
folder and flyspray.log
even though the Unix permissions look correct. This is a very common gotcha when migrating from Bitnami.

You can verify SELinux is the issue after boot by running:

sudo ausearch -m avc -ts recent | grep httpd

lamp_8_bitnami
is actually still active (not truly deprecated in the API sense) — but AWS has released a newer first-party replacement:
Use lamp_ls_1_0
— LAMP PHP 8.5.12 (AWS-native, not Bitnami)

blueprint_id = "lamp_ls_1_0"

This is the new AWS-managed LAMP stack (the _ls_1_0
suffix = "Lightsail 1.0", AWS's own stack replacing Bitnami). Key differences that affect your user_data
script:
Item	lamp_8_bitnami
(old)	lamp_ls_1_0
(new)
PHP config path	/opt/bitnami/php/etc/php.ini
	/etc/php.ini
or /etc/php.d/
Web root	/opt/bitnami/apache/htdocs
	/var/www/html
Restart command	/opt/bitnami/ctlscript.sh restart apache
	systemctl restart httpd
or apache2
User	bitnami
	apache
or ec2-user
SSL tool	bncert-tool
	Use certbot
directly

### Outputs

Outputs:

app_url = "https://flyspray.enviroweather.net"
db_endpoint = "ls-02d346a02a4b8f66dcec27e73aad585277082c4b.c5k4kueayxhx.us-east-2.rds.amazonaws.com"
db_instance_name = "ewx-flyspray-db"
db_port = 5432
flyspray_conf_path = "./output/flyspray.conf.php"
instance_name = "flyspray-app"
next_steps = <<EOT

---- NEXT STEPS (in order) ----

Note: Flyspray and flyspray.conf.php are automatically installed and
configured on the Lightsail instance on first boot via user_data.

1. Create GoDaddy DNS A record:
     Name:  flyspray
     Value: 3.138.88.53
     TTL:   600

2. Run the DB import (loads dump from S3 into managed PostgreSQL):
     cd terraform/
     ./scripts/import_db.sh

3. Wait for DNS propagation:
     dig +short flyspray.enviroweather.net   # should return 3.138.88.53

4. Provision SSL (Let's Encrypt):
     output/setup_ssl.sh

5. Open https://flyspray.enviroweather.net

To tear everything down:
     terraform destroy

EOT
region = "us-east-2"
s3_bucket = "ewx-flyspray-config-941061635635-us-east-2-an"
s3_dump_key = "flyspray_22_10_2026.sql"
setup_ssl_path = "./output/setup_ssl.sh"
static_ip = "3.138.88.53"


### IAM policies

we don't have good AWS IAM here at msu. you have to use an IAM user

you have to give that user access to lightsail stuff for this to work

```
export FLYSPRAY_IAM_USER=
aws iam put-user-policy \
  --user-name $FLYSPRAY_IAM_USER \
  --policy-name LightsailFullAccess \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "lightsail:*",
        "Resource": "*"
      }
    ]
  }'

```

---

## How CLI + MFA works for IAM users

Your IAM user has a long-term access key (the AWS_ACCESS_KEY_ID
/ AWS_SECRET_ACCESS_KEY
stored on disk). MFA adds a second factor by requiring you to get a temporary session token before running commands. The flow is:

    You run one command with your long-term key + a 6-digit MFA code
    AWS returns temporary credentials (valid for up to 12 hours)
    You use those temporary credentials for all your actual work

Step-by-step setup
Step 1: Assign a virtual MFA device to billspat-ewx

    Go to IAM → Users → billspat-ewx → Security credentials tab 
    Under Multi-factor authentication (MFA), click Assign MFA device
    Choose Authenticator app (Google Authenticator, Authy, 1Password, etc. — any TOTP app works)
    Scan the QR code and enter two consecutive codes to confirm
    Note the MFA device ARN — it looks like: arn:aws:iam::941061635635:mfa/billspat-ewx

Step 2: Get a temporary session token via CLI

aws sts get-session-token \
  --serial-number arn:aws:iam::941061635635:mfa/billspat-ewx \
  --token-code 123456 \
  --duration-seconds 43200
Run in CloudShell

Replace 123456
with the current 6-digit code from your authenticator app. 43200
= 12 hours.

This returns:

{
  "Credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "...",
    "SessionToken": "...",
    "Expiration": "2026-11-17T13:44:00Z"
  }
}

Step 3: Use the temporary credentials

You have two options:

Option A — Export as environment variables (easiest, lasts for your terminal session):

export AWS_ACCESS_KEY_ID=ASIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
Run in CloudShell

Then run your normal aws lightsail ...
commands as usual.

Option B — Add a named profile to ~/.aws/credentials
:

[billspat-mfa]
aws_access_key_id = ASIA...
aws_secret_access_key = ...
aws_session_token = ...

Then use --profile billspat-mfa
on your commands, or set export AWS_PROFILE=billspat-mfa
.
Making it less painful — a helper script

Since you'll do this regularly, a small shell script saves time:

#!/bin/bash
# get-mfa-creds.sh
read -p "Enter MFA code: " MFA_CODE
CREDS=$(aws sts get-session-token \
  --serial-number arn:aws:iam::941061635635:mfa/billspat-ewx \
  --token-code $MFA_CODE \
  --duration-seconds 43200 \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")
echo "Temporary credentials set — valid for 12 hours."
Run in CloudShell

Run it with source get-mfa-creds.sh
(must use source
so the exports apply to your current shell).
Summary
	Long-term key (current)	With MFA
Stored on disk	✅	✅ (same key stays on disk)
Needs SSO/Control Tower	❌	❌
Needs institution support	❌	❌
Protected if key is leaked	❌	✅
Extra step to start working	None	~30 seconds once per 12 hours

No SSO, no Control Tower, no institution involvement needed — it's entirely self-contained to your IAM user and a free authenticator app on your phone.


---



### prompt for holding on to the IP Address

thank you for this.   can you confirm that this is the curre  workflow very broadly : build on aws -> get an IP assigned -> update godaddy DNS  .  I already have to setup the S3 bucket separately to hold the SQL dump file. That means that is some prequisite AWS setup to do before building.  Could I also get an IP address from AWS before building this that I can re-use and hold on-to if I need to build again (because it didn't work OR because I did something wrong in the terraform code).  updating the IP in GoDaddy is time consuming and it takes a while to propagate.   I do not have enough experience with Terraform to know how to update/fix part of this architecture and leaving other parts - specifically the IPv4 address assignment -  alone.  Is this a better workflow to el
1. setup s3 and get an AWS IPv4 address-> 
2. update subdomain DNS On godaddy -> 
3. set IP and s3 on tfvars
4. build with TF, using the IP address for lightsail (don't provision a new one) -> 
5. find a problem / fix TF  or script issue -> 
6. rebuild with TF -> 
7. iterate 5 and 6 until awesome

