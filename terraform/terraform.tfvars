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
# =============================================================================

region      = "us-east-1"
environment = "prod"

# --- Instance ---
instance_name   = "flyspray-app"
instance_bundle = "micro_3_0"      # $7/mo — change to nano_3_0 for dev/test

# --- Hostname and SSL (required — no default) ---
app_hostname = "flyspray.enviroweather.net"   # <- CHANGE THIS
ssl_email    = "billspat@msu.edu"        # <- CHANGE THIS

# --- Database ---
db_instance_name = "ewx-flyspray-db"
db_bundle        = "micro_2_0"     # $15/mo — change to micro_2_0 for dev/test

# --- Application DB / user ---
app_db   = "flyspray"
app_user = "flyspray_user"

# --- Snapshot schedule (UTC) ---
instance_snapshot_time = "02:00"
db_backup_window       = "03:00-03:30"

# --- S3 dump source ---
s3_bucket   = "ewx-flyspray-941061635635-us-east-1-an"
s3_dump_key = "flyspray_22_10_2026.sql"

# =============================================================================
# Dev/test override — copy to terraform.dev.tfvars and run:
#   terraform apply -var-file=terraform.dev.tfvars
# =============================================================================
# environment      = "dev"
# instance_name    = "flyspray-dev"
# instance_bundle  = "nano_3_0"
# db_instance_name = "flyspray-dev-db"
# app_hostname     = "flyspray-dev.yourdomain.com"