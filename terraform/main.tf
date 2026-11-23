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

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    created_by  = var.created_by
    project     = var.project
    build_ver   = var.build_ver
    environment = var.environment
  }

  az = "${var.region}a"
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

  lifecycle {
    prevent_destroy = true
  }
}