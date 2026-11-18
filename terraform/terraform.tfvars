# =============================================================================
# terraform.tfvars
# Non-secret defaults — safe to commit to version control.
#
# DO NOT put db_master_password or app_password here.
# Set secrets via environment before running terraform:
#
#   export TF_VAR_db_master_password="..."
#   export TF_VAR_app_password="..."
#
# Or avoid shell history with read -s:
#   read -s -p "DB master password: " TF_VAR_db_master_password && export TF_VAR_db_master_password
#   read -s -p "App password: "       TF_VAR_app_password       && export TF_VAR_app_password
# 
# Or avoid shell history and save in .env file (in .gitignore)
#  - file contents
# export TF_VAR_db_master_password="..."
# export TF_VAR_app_password="..."
#
# - execute
# source .env
# =============================================================================

region      = "us-east-2"
environment = "prod"

# --- Legacy static IP name (kept stable; do not change) ---
instance_name = "flyspray-app"

# --- Hostname (required — no default) ---
app_hostname = "flyspray.enviroweather.net"

# --- Database ---
db_instance_name = "ewx-flyspray-db"
db_bundle        = "micro_2_0" # $15/mo — change to micro_2_0 for dev/test

# --- Application DB / user ---
app_db   = "ewx_flyspray"
app_user = "ewx_flyspray_user"

# --- Snapshot schedule (UTC) ---
db_backup_window = "03:00-03:30"

# --- S3 dump source ---
s3_bucket   = "ewx-flyspray-config-941061635635-us-east-2-an"
s3_dump_key = "flyspray_22_10_2026.sql"

# --- Container build/deploy (non-secret) ---
# image_tag       = "latest"
# deploy_flyspray = false   # flip to true after the first successful CodeBuild run
# db_prefix       = "flyspray_"

# =============================================================================
# Dev/test override — copy to terraform.dev.tfvars and run:
#   terraform apply -var-file=terraform.dev.tfvars
# =============================================================================
# environment      = "dev"
# instance_name    = "flyspray-dev"
# db_instance_name = "flyspray-dev-db"
# app_hostname     = "flyspray-dev.enviroweather.net"