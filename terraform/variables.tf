# =============================================================================
# variables.tf
# All inputs mirror the FLYSPRAY_* env vars from the shell script.
# Secrets (db_master_password, app_password) have no default and must
# be supplied via TF_VAR_* environment variables — never in tfvars files.
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

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------
variable "instance_name" {
  description = "Lightsail instance name. Change for dev/test deployments."
  type        = string
  default     = "flyspray-app"
}

variable "instance_bundle" {
  description = "Lightsail instance bundle ID. See: aws lightsail get-bundles."
  type        = string
  default     = "micro_3_0"   # $7/mo — 1 GB RAM, 40 GB disk
}

variable "instance_snapshot_time" {
  description = "UTC time for daily automatic instance snapshot (HH:MM)."
  type        = string
  default     = "02:00"
}

# ---------------------------------------------------------------------------
# Hostname and SSL
# ---------------------------------------------------------------------------
variable "app_hostname" {
  description = "Custom subdomain for Flyspray (e.g. flyspray.example.com). Required."
  type        = string

  validation {
    condition     = length(var.app_hostname) > 0
    error_message = "app_hostname must not be empty."
  }
}

variable "ssl_email" {
  description = "Email for Let's Encrypt expiry notifications. Required."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.ssl_email))
    error_message = "ssl_email must be a valid email address."
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
  default     = "micro_2_0"   # $15/mo — 1 GB RAM, 40 GB
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
  default     = "ewx-flyspray-941061635635-us-east-1-an"
}

variable "s3_dump_key" {
  description = "S3 object key for the SQL dump file."
  type        = string
  default     = "flyspray_22_10_2026.sql"
}