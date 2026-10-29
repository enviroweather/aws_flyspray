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
# Lightsail instance (LAMP PHP 8 Bitnami)
# ---------------------------------------------------------------------------
resource "aws_lightsail_instance" "flyspray" {
  name              = var.instance_name
  availability_zone = local.az
  blueprint_id      = "lamp_8_bitnami"
  bundle_id         = var.instance_bundle

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
# setup_ssl.sh — written to output/ after apply, ready to run post-DNS
# ---------------------------------------------------------------------------
resource "local_file" "setup_ssl" {
  filename        = "${path.module}/output/setup_ssl.sh"
  file_permission = "0750"

  content = <<-BASH
    #!/usr/bin/env bash
    # Generated by Terraform — run AFTER DNS A record is live and propagated.
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

    echo "Provisioning Let's Encrypt certificate..."
    aws lightsail ssh \
      --instance-name "$INSTANCE_NAME" \
      --region "$REGION" \
      -- sudo /opt/bitnami/bncert-tool \
           --domain "$APP_HOSTNAME" \
           --email  "$SSL_EMAIL" \
           --enable-https \
           --enable-redirect \
           --agree-tos

    echo "SSL provisioning complete. Visit https://$APP_HOSTNAME"
    BASH
}