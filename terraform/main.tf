# =============================================================================
# main.tf
# Flyspray on AWS Lightsail — Terraform
# Manages: instance, managed PostgreSQL DB, static IP, firewall rules,
#          automatic snapshots, flyspray.conf.php, and setup_ssl.sh.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # Recommended: store state in S3 so the team shares it.
  # Uncomment and fill in your bucket name before first run.
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "flyspray/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Locals — derived values
# ---------------------------------------------------------------------------
locals {
  az             = "${var.region}a"
  static_ip_name = "${var.instance_name}-static-ip"
}

# ---------------------------------------------------------------------------
# Lightsail instance (LAMP PHP 8 - AWS native lamp_ls_1_0)
# ---------------------------------------------------------------------------
resource "aws_lightsail_instance" "flyspray" {
  name              = var.instance_name
  availability_zone = local.az
  blueprint_id      = "lamp_ls_1_0"
  bundle_id         = var.instance_bundle

  # Automatically install Flyspray and configure Apache / PHP on first boot
  user_data = <<-EOF
      #!/bin/bash
      set -e
      exec > /var/log/flyspray-setup.log 2>&1
      echo "Starting automated Flyspray setup..."

      # 1. Wait for cloud-init / yum lock to release (lamp_ls_1_0 runs its own
      #    post-boot setup; give it up to 2 minutes before we proceed)
      for i in $(seq 1 24); do
        if ! pgrep -x yum > /dev/null && ! pgrep -x dnf > /dev/null; then
          break
        fi
        echo "Waiting for package manager to be free... ($i)"
        sleep 5
      done

      # 2. Install PostgreSQL 16 client + PHP PostgreSQL extensions
      dnf install -y postgresql16 php-pdo php-pgsql php-pdo_pgsql

      # 3. Enable pdo_pgsql / pgsql in PHP config
      #    lamp_ls_1_0 drops extension configs in /etc/php.d/
      #    The dnf install above usually creates these automatically, but
      #    ensure they are not commented out just in case.
      PHP_D="/etc/php.d"
      for ext in pdo_pgsql pgsql; do
        if [ -f "$PHP_D/30-$ext.ini" ]; then
          sed -i "s/^;extension=$ext/extension=$ext/" "$PHP_D/30-$ext.ini"
        else
          echo "extension=$ext" > "$PHP_D/30-$ext.ini"
        fi
      done

      # 4. Restart PHP-FPM to pick up new extensions
      systemctl restart php-fpm

      # 5. Download and extract Flyspray into the web root
      HTDOCS="/var/www/html"
      cd /tmp

      FLYSPRAY_URL="https://github.com/flyspray/flyspray/releases/download/v${var.flyspray_version}/flyspray-${var.flyspray_version}.tar.gz"
      echo "Downloading Flyspray from $FLYSPRAY_URL..."
      wget -q "$FLYSPRAY_URL" -O flyspray.tar.gz
      tar -xzf flyspray.tar.gz

      # Remove default LAMP welcome page
      rm -f "$HTDOCS/index.html" "$HTDOCS/index.php"

      # Copy Flyspray files into Apache root
      cp -a flyspray/. "$HTDOCS/"
      rm -rf flyspray flyspray.tar.gz

      # 6. Write flyspray.conf.php
      cat > "$HTDOCS/flyspray.conf.php" << 'CONF'
  <?php
  ####################################################################
  # Flyspray configuration file - generated automatically by Terraform
  # Location: /var/www/html/flyspray.conf.php
  ####################################################################

  [database]
  dbtype   = pgsql
  host     = ${aws_lightsail_database.flyspray.master_endpoint_address}
  port     = ${aws_lightsail_database.flyspray.master_endpoint_port}
  dbname   = ${var.app_db}
  dbprefix = flyspray_
  dbuser   = ${var.app_user}
  dbpass   = ${var.app_password}

  [general]
  base_url      = https://${var.app_hostname}
  attachmentdir = ./attachments
  logfile       = ./flyspray.log
  CONF

      # 7. Set directory and file permissions
      mkdir -p "$HTDOCS/attachments"
      touch "$HTDOCS/flyspray.log"
      chown -R apache:apache "$HTDOCS"
      chmod -R 775 "$HTDOCS/attachments"
      chmod 664 "$HTDOCS/flyspray.log"
      chmod 640 "$HTDOCS/flyspray.conf.php"

      # 8. Allow Apache to write to attachments (SELinux is active on AL2023)
      setsebool -P httpd_unified 1 || true
      chcon -Rt httpd_sys_rw_content_t "$HTDOCS/attachments" || true
      chcon -t httpd_sys_rw_content_t "$HTDOCS/flyspray.log" || true
      chcon -t httpd_sys_content_t "$HTDOCS/flyspray.conf.php" || true

      # 9. Restart Apache
      systemctl restart httpd
      echo "Flyspray automated setup complete."
    EOF

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# Instance firewall — HTTP (Let's Encrypt challenge) + HTTPS + SSH
# ---------------------------------------------------------------------------
resource "aws_lightsail_instance_public_ports" "flyspray" {
  instance_name = aws_lightsail_instance.flyspray.name

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }

  # SSH — restrict to your team's IPs in production
  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }
}

# ---------------------------------------------------------------------------
# Static IP — allocated and attached to the instance
# ---------------------------------------------------------------------------
resource "aws_lightsail_static_ip" "flyspray" {
  name = local.static_ip_name
}

resource "aws_lightsail_static_ip_attachment" "flyspray" {
  static_ip_name = aws_lightsail_static_ip.flyspray.name
  instance_name  = aws_lightsail_instance.flyspray.name
}

# ---------------------------------------------------------------------------
# Automatic instance snapshots (daily, 7-day retention)
# The Terraform AWS provider does not yet expose Lightsail add-ons natively,
# so we use a null_resource local-exec as the standard workaround.
# ---------------------------------------------------------------------------
resource "null_resource" "instance_auto_snapshot" {
  depends_on = [aws_lightsail_instance.flyspray]

  provisioner "local-exec" {
    command = <<-EOT
      aws lightsail enable-add-on \
        --resource-name ${var.instance_name} \
        --add-on-request "addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=${var.instance_snapshot_time}}" \
        --region ${var.region}
    EOT
  }

  triggers = {
    instance_name = var.instance_name
    snapshot_time = var.instance_snapshot_time
  }
}

# ---------------------------------------------------------------------------
# Managed PostgreSQL database
# ---------------------------------------------------------------------------
resource "aws_lightsail_database" "flyspray" {
  relational_database_name = var.db_instance_name
  availability_zone        = local.az
  blueprint_id             = "postgres_16"
  bundle_id                = var.db_bundle
  master_database_name     = "postgres"
  master_username          = "dbmaster"
  master_password          = var.db_master_password
  publicly_accessible      = false
  backup_retention_enabled = true
  preferred_backup_window  = var.db_backup_window
  # skip_final_snapshot = true means no extra snapshot charge on destroy.
  # Set to false in production if you want a final backup kept on terraform destroy.
  skip_final_snapshot      = true

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# flyspray.conf.php — written to output/ after apply
# Copy to /opt/bitnami/apache/htdocs/ on the instance (see outputs)
# ---------------------------------------------------------------------------
resource "local_file" "flyspray_conf" {
  filename        = "${path.module}/output/flyspray.conf.php"
  file_permission = "0640"

  content = <<-PHP
    <?php
    ####################################################################
    # Flyspray configuration file — generated by Terraform
    # Copy to: /opt/bitnami/apache/htdocs/flyspray.conf.php
    ####################################################################

    [database]
    dbtype   = pgsql
    host     = ${aws_lightsail_database.flyspray.master_endpoint_address}
    port     = ${aws_lightsail_database.flyspray.master_endpoint_port}
    dbname   = ${var.app_db}
    dbprefix = flyspray_
    dbuser   = ${var.app_user}
    dbpass   = ${var.app_password}

    [general]
    base_url      = https://${var.app_hostname}
    attachmentdir = ./attachments
    logfile       = ./flyspray.log
    PHP
}

# ---------------------------------------------------------------------------
# setup_ssl.sh - written to output/ after apply, ready to run post-DNS
# ---------------------------------------------------------------------------
resource "local_file" "setup_ssl" {
  filename        = "${path.module}/output/setup_ssl.sh"
  file_permission = "0750"

  content = <<-BASH
    #!/usr/bin/env bash
    # Generated by Terraform - run AFTER DNS A record is live and propagated.
    # Verify: dig +short ${var.app_hostname}
    #         # should return: ${aws_lightsail_static_ip.flyspray.ip_address}
    set -euo pipefail

    REGION="${var.region}"
    INSTANCE_NAME="${var.instance_name}"
    APP_HOSTNAME="${var.app_hostname}"
    SSL_EMAIL="${var.ssl_email}"
    INSTANCE_IP="${aws_lightsail_static_ip.flyspray.ip_address}"

    echo "Verifying DNS for $APP_HOSTNAME..."
    RESOLVED=$(dig +short "$APP_HOSTNAME" | tail -1)
    if [[ "$RESOLVED" != "$INSTANCE_IP" ]]; then
      echo "ERROR: $APP_HOSTNAME -> '$RESOLVED', expected '$INSTANCE_IP'. Wait for DNS propagation."
      exit 1
    fi
    echo "DNS OK: $APP_HOSTNAME -> $INSTANCE_IP"

    echo "Installing certbot and Apache plugin..."
    sudo dnf install -y certbot python3-certbot-apache

    echo "Provisioning Let's Encrypt certificate for $APP_HOSTNAME..."
    sudo certbot --apache \
      --domain "$APP_HOSTNAME" \
      --email  "$SSL_EMAIL" \
      --agree-tos \
      --non-interactive \
      --redirect

    echo "Verifying auto-renewal timer is active..."
    sudo systemctl enable --now certbot-renew.timer
    sudo systemctl status certbot-renew.timer --no-pager

    echo "SSL provisioning complete. Visit https://$APP_HOSTNAME"
    BASH
}

# ---------------------------------------------------------------------------
# setup_db.sh - written to output/ after apply
# Run once after terraform apply to create the app user and database.
# Requires: postgresql16 client installed locally, or run from the instance.
# ---------------------------------------------------------------------------
resource "local_file" "setup_db" {
  filename        = "${path.module}/output/setup_db.sh"
  file_permission = "0750"

  content = <<-BASH
    #!/usr/bin/env bash
    # Generated by Terraform - run once after terraform apply.
    # Creates the Flyspray app user and database in the managed PostgreSQL instance.
    # Requires psql client: sudo dnf install -y postgresql16
    set -euo pipefail

    DB_HOST="${aws_lightsail_database.flyspray.master_endpoint_address}"
    DB_PORT="${aws_lightsail_database.flyspray.master_endpoint_port}"
    DB_MASTER_USER="dbmaster"
    APP_DB="${var.app_db}"
    APP_USER="${var.app_user}"

    # Prompt for passwords at runtime - never store them in the script
    read -rsp "Enter dbmaster password: " DB_MASTER_PASS
    echo
    read -rsp "Enter app_user password (for $APP_USER): " APP_PASS
    echo

    export PGPASSWORD="$DB_MASTER_PASS"

    echo "Connecting to $DB_HOST:$DB_PORT as $DB_MASTER_USER..."

    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" -d postgres << SQL
    -- 1. Create the app user (skip if already exists)
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$APP_USER') THEN
        CREATE USER "$APP_USER" WITH PASSWORD '$APP_PASS';
        RAISE NOTICE 'User $APP_USER created.';
      ELSE
        RAISE NOTICE 'User $APP_USER already exists, skipping.';
      END IF;
    END
    \$\$;

    -- 2. Create the app database (skip if already exists)
    SELECT 'CREATE DATABASE "$APP_DB" OWNER "$APP_USER"'
    WHERE NOT EXISTS (
      SELECT FROM pg_database WHERE datname = '$APP_DB'
    )\gexec

    -- 3. Grant privileges
    GRANT ALL PRIVILEGES ON DATABASE "$APP_DB" TO "$APP_USER";

    -- 4. Confirm
    SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname = '$APP_USER';
    SELECT datname, pg_catalog.pg_get_userbyid(datdba) AS owner
      FROM pg_database WHERE datname = '$APP_DB';
    SQL

    # Connect to the new DB to grant schema privileges
    export PGPASSWORD="$DB_MASTER_PASS"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" -d "$APP_DB" << SQL
    GRANT ALL ON SCHEMA public TO "$APP_USER";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
      GRANT ALL ON TABLES TO "$APP_USER";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
      GRANT ALL ON SEQUENCES TO "$APP_USER";
    SQL

    unset PGPASSWORD
    echo ""
    echo "Database setup complete."
    echo "  Host:     $DB_HOST:$DB_PORT"
    echo "  Database: $APP_DB"
    echo "  App user: $APP_USER"
    echo ""
    echo "Next step: restore your pg_dump:"
    echo "  PGPASSWORD='<app_pass>' pg_restore -h $DB_HOST -p $DB_PORT -U $APP_USER -d $APP_DB -v flyspray_dump.dump"
    echo "  # or for plain SQL dump:"
    echo "  PGPASSWORD='<app_pass>' psql -h $DB_HOST -p $DB_PORT -U $APP_USER -d $APP_DB < flyspray_dump.sql"
    BASH
}
