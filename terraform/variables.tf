# =============================================================================
# variables.tf
# Secrets (db_master_password, app_password, cookie_salt) have no default and
# must be supplied via TF_VAR_* environment variables, e.g. sourced from .env
# — never in tfvars files.
# =============================================================================

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label used in resource tags (prod, dev, test)."
  type        = string
  default     = "prod"
}

variable "instance_name" {
  description = "Legacy name kept only to preserve the protected static IP's resource name."
  type        = string
  default     = "flyspray-app"
}

variable "flyspray_version" {
  description = "Flyspray release tag that CodeBuild downloads and bakes into the image."
  type        = string
  default     = "1.0-rc11"
}

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------
variable "app_hostname" {
  description = "Custom subdomain for Flyspray (e.g. flyspray.example.com). Required."
  type        = string

  validation {
    condition     = length(var.app_hostname) > 0
    error_message = "app_hostname must not be empty."
  }
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
variable "db_instance_name" {
  description = "Lightsail managed database instance name."
  type        = string
  default     = "flyspray-db"
}

variable "db_bundle" {
  description = "Lightsail database bundle ID. See: aws lightsail get-relational-database-bundles."
  type        = string
  default     = "micro_2_0" # $15/mo — 1 GB RAM, 40 GB
}

variable "db_backup_window" {
  description = "Preferred UTC backup window for the managed database (HH:MM-HH:MM, 30-min slot)."
  type        = string
  default     = "03:00-03:30"
}

variable "db_master_password" {
  description = "Master password for managed PostgreSQL. SECRET — no default. Set via TF_VAR_db_master_password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_master_password) >= 8
    error_message = "db_master_password must be at least 8 characters."
  }
}

# ---------------------------------------------------------------------------
# Application DB / user
# ---------------------------------------------------------------------------
variable "app_db" {
  description = "PostgreSQL database name for Flyspray."
  type        = string
  default     = "flyspray"
}

variable "app_user" {
  description = "PostgreSQL application user for Flyspray."
  type        = string
  default     = "flyspray_user"
}

variable "app_password" {
  description = "Password for the Flyspray app DB user. SECRET — no default. Set via TF_VAR_app_password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.app_password) >= 8
    error_message = "app_password must be at least 8 characters."
  }
}

# ---------------------------------------------------------------------------
# S3 dump source
# ---------------------------------------------------------------------------
variable "s3_bucket" {
  description = "S3 bucket containing the Flyspray SQL dump."
  type        = string
  default     = ""
}

variable "s3_dump_key" {
  description = "S3 object key for the SQL dump file."
  type        = string
  default     = ""
}

variable "created_by" {
  description = "Deployment identity supplied through TF_VAR_created_by, preferably evaluated from the current OS user in a local .env file."
  type        = string

  validation {
    condition     = length(trimspace(var.created_by)) > 0
    error_message = "created_by must not be empty. Set TF_VAR_created_by from $USER on Mac/Linux or the equivalent Windows username."
  }
}

variable "project" {
  description = "Stable project identifier applied to taggable AWS resources for billing and inventory."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_.:/=+@-]*$", var.project))
    error_message = "project must be a non-empty AWS tag-safe identifier."
  }
}

variable "build_ver" {
  description = "One-time UTC timestamp for this deployment, supplied with TF_VAR_build_ver=$(date -u '+%Y-%m-%dT%H:%M:%SZ') or -var=build_ver=$(date -u '+%Y-%m-%dT%H:%M:%SZ') . Generate once and keep stable across repeated plans."
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", var.build_ver))
    error_message = "build_ver must be a UTC ISO 8601 timestamp, for example 2026-11-18T03:43:43Z."
  }
}