# Flyspray on AWS Lightsail with PostgreSQL

This repository contains the [Terraform](https://www.terraform.io/) configuration and automation scripts to deploy [Flyspray](https://www.flyspray.org/), a lightweight web-based bug and issue tracking system written in PHP, to **AWS Lightsail** backed by a **managed PostgreSQL database**.

---

## Architecture Overview

```
                        +----------------------------+
                        |   Internet / Web Browser   |
                        +--------------+-------------+
                                       |
                              HTTPS (Port 443)
                                       v
                    +-------------------------------------+
                    |     Lightsail Static IPv4           |
                    |   (flyspray.yourdomain.com)         |
                    +------------------+------------------+
                                       |
+--------------------------------------v--------------------------------------+
| AWS Lightsail Instance (LAMP PHP 8 Bitnami)                                 |
|                                                                             |
|  - OS: Debian-based Bitnami Linux (micro_3_0: 1 GB RAM, 40 GB SSD, ~$7/mo)  |
|  - Apache 2.4 serving Flyspray on root (/)                                  |
|  - PHP 8.x with pdo_pgsql & pgsql extensions enabled                        |
|  - Automatic first-boot provisioning via user_data (cloud-init):            |
|      * Downloads Flyspray release tarball                                   |
|      * Configures Apache & sets bitnami:daemon permissions                  |
|      * Injects flyspray.conf.php with database credentials                  |
|  - Let's Encrypt SSL via Bitnami bncert-tool (auto HTTP -> HTTPS redirect)  |
|  - Daily automatic instance snapshot (02:00 UTC, 7-day retention)          |
+--------------------------------------+--------------------------------------+
                                       | Private Lightsail VPC
                             PostgreSQL (Port 5432)
                                       v
+-----------------------------------------------------------------------------+
| AWS Lightsail Managed Database                                              |
|                                                                             |
|  - Engine: PostgreSQL 16 (micro_2_0: 1 GB RAM, 40 GB SSD, ~$15/mo)         |
|  - Private access only (public access temporarily opened during DB import)   |
|  - Automated daily backups (window: 03:00–03:30 UTC, 7-day retention)        |
+-----------------------------------------------------------------------------+
```

### Component Details
* **Lightsail Instance (`lamp_8_bitnami`)**: Runs the web application. Using Lightsail instead of standard EC2 provides predictable monthly billing, bundled egress bandwidth, and simplified firewall management.
* **Managed PostgreSQL 16 Database**: Relational database service managed by Lightsail with automatic daily backups and point-in-time restore capability.
* **Static IP**: Fixed public IPv4 allocated once and bound to the instance, ensuring reboots or instance replacement won't break DNS records.
* **Automated Bootstrapping (`user_data`)**: The instance self-installs Flyspray and configures Apache/PHP on first boot, eliminating manual SSH/tarball extraction.
* **Separation of Concerns**: Infrastructure state is fully managed by Terraform, while one-time data migration (SQL dump import) and interactive SSL certification are handled by clean, companion bash scripts.

---

## Prerequisites

1. **AWS Account & CLI**:
   * An active AWS account with permissions to manage Lightsail and S3.
   * AWS credentials configured locally (`aws configure`).
2. **Workstation Tools**:
   * **Terraform** (or OpenTofu): `brew install hashicorp/tap/terraform`
   * **AWS CLI v2**: `brew install awscli`
   * **PostgreSQL Client (`psql`)**: `brew install libpq`
3. **Database Dump**:
   * An existing Flyspray PostgreSQL SQL dump file stored in an S3 bucket (e.g. `s3://your-bucket/flyspray_dump.sql`).
4. **Domain / DNS**:
   * A subdomain (e.g. `flyspray.enviroweather.net`) managed via your DNS registrar (GoDaddy, Route53, etc.).

---

## Repository Structure

```
aws_flyspray/
├── README.md
├── terraform/
│   ├── main.tf           # Lightsail instance, DB, static IP, firewall, user_data
│   ├── variables.tf      # Input variables and validation rules
│   ├── outputs.tf        # Static IP, DB endpoints, and post-apply guide
│   ├── terraform.tfvars  # Non-secret configuration (domain, email, region, bundles)
│   ├── scripts/
│   │   └── import_db.sh  # Downloads S3 dump, configures DB user/schema, loads data
│   └── output/           # (Generated after apply)
│       ├── flyspray.conf.php  # Local backup copy of application config
│       └── setup_ssl.sh       # Let's Encrypt certificate provisioning script
```

---

## Deployment Workflow

Always run Terraform from your **local machine / laptop** rather than ephemeral cloud shells, ensuring your `terraform.tfstate` file is safely persisted on disk.

### Step 1: Review Configuration

Inspect `terraform/terraform.tfvars` and update your settings if needed:
```hcl
region          = "us-east-1"
instance_name   = "flyspray-app"
instance_bundle = "micro_3_0"       # $7/month

app_hostname    = "flyspray.enviroweather.net"
ssl_email       = "your-email@example.com"

db_instance_name = "ewx-flyspray-db"
db_bundle        = "micro_2_0"      # $15/month
app_db           = "flyspray"
app_user         = "flyspray_user"

s3_bucket   = "your-s3-bucket-name"
s3_dump_key = "flyspray_22_10_2026.sql"
```

### Step 2: Set Passwords in Your Shell

Export your database passwords as environment variables (never commit passwords to `.tfvars` files):

```bash
export TF_VAR_db_master_password="YourSecureMasterPassword"
export TF_VAR_app_password="YourSecureAppPassword"
```

### Step 3: Initialize and Apply Terraform

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

* **What happens**: Terraform provisions the PostgreSQL database, allocates the static IP, launches the LAMP instance, and runs the `user_data` script to download and install Flyspray.
* *Note: Lightsail databases typically take 8–12 minutes to reach the `available` state.*
* When finished, Terraform outputs your **Static IP** and post-apply checklist.

### Step 4: Configure DNS

Log into your DNS provider (e.g., GoDaddy) and add an **A record**:
* **Host / Name**: `flyspray` (or your subdomain prefix)
* **Value / Points to**: `<STATIC_IP>` (from `terraform output static_ip`)
* **TTL**: 600 (10 minutes)

### Step 5: Import the PostgreSQL Dump

Run the import script:
```bash
./scripts/import_db.sh
```

* **What happens**:
  1. Temporarily enables public accessibility on the managed database.
  2. Downloads the SQL dump file from S3 (`/tmp/flyspray_dump.sql`).
  3. Connects via `psql` to grant necessary public schema privileges (PostgreSQL 15+ compatible), creates the application user and database, and imports the SQL dump.
  4. Grants all privileges on imported tables, sequences, and functions to the application user.
  5. Disables public accessibility on the database for security.

### Step 6: Provision SSL Certificate

Once DNS has propagated (verify with `dig +short flyspray.yourdomain.com` returning your static IP):
```bash
output/setup_ssl.sh
```

This runs Bitnami's `bncert-tool` over SSH on the instance to obtain a Let's Encrypt certificate and configure automatic HTTP-to-HTTPS redirection.

### Step 7: Open in Browser

Visit `https://flyspray.yourdomain.com` — Flyspray is live and connected to your imported database!

---

## Terraform Operations & Troubleshooting

### Resuming / Converging State
Terraform is declarative and idempotent. If a network blip or timeout occurs at any point:
```bash
terraform apply
```
Terraform compares the AWS state with your code and resumes only what remains to be created.

### Replacing / Rebuilding a Single Component
If the application instance ever gets into a bad state and you want to recreate **only the web server** without touching the database or static IP:
```bash
terraform apply -replace="aws_lightsail_instance.flyspray"
```

### Checking Instance Bootstrap Logs
If you need to verify the automated Flyspray installation on the instance:
```bash
aws lightsail ssh --instance-name flyspray-app --region us-east-1
cat /var/log/flyspray-setup.log
```

### Teardown / Destroy
To permanently delete all resources and stop all AWS charges:
```bash
terraform destroy
```

---

## Snapshot & Disaster Recovery Reference

### Automatic Snapshots
* **Instance**: Daily at `02:00 UTC` (retained for 7 days).
* **Database**: Daily automatic backup window `03:00–03:30 UTC` (retained for 7 days).

### Restoring from a Snapshot (AWS CLI)

#### 1. Restore an Instance from a Snapshot:
```bash
aws lightsail create-instances-from-snapshot \
  --instance-snapshot-name "flyspray-app-snapshot-name" \
  --instance-names "flyspray-app-restored" \
  --region us-east-1 \
  --availability-zone us-east-1a \
  --bundle-id micro_3_0
```
Then re-attach the static IP to the restored instance:
```bash
aws lightsail attach-static-ip \
  --static-ip-name flyspray-app-static-ip \
  --instance-name flyspray-app-restored \
  --region us-east-1
```

#### 2. Restore a Database from a Snapshot:
```bash
aws lightsail create-relational-database-from-snapshot \
  --relational-database-snapshot-name "flyspray-db-snapshot-name" \
  --relational-database-name "ewx-flyspray-db-restored" \
  --availability-zone us-east-1a \
  --region us-east-1
```
