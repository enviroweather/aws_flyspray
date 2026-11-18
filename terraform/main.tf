terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region
}

locals {
  az             = "${var.region}a"
  static_ip_name = "${var.instance_name}-static-ip"
}

resource "aws_lightsail_static_ip" "flyspray" {
  name = local.static_ip_name

  lifecycle {
    prevent_destroy = true
  }
}

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
  skip_final_snapshot      = true

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }

  lifecycle {
    prevent_destroy = true
  }
}