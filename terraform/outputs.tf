# =============================================================================
# outputs.tf
# =============================================================================

output "instance_name" {
  description = "Lightsail instance name."
  value       = aws_lightsail_instance.flyspray.name
}

output "static_ip" {
  description = "Static IPv4 address. Use this for your GoDaddy A record."
  value       = aws_lightsail_static_ip.flyspray.ip_address
}

output "db_instance_name" {
  description = "Lightsail managed database instance name."
  value       = aws_lightsail_database.flyspray.relational_database_name
}

output "db_endpoint" {
  description = "Managed PostgreSQL endpoint address."
  value       = aws_lightsail_database.flyspray.master_endpoint_address
}

output "db_port" {
  description = "Managed PostgreSQL port."
  value       = aws_lightsail_database.flyspray.master_endpoint_port
}

output "app_url" {
  description = "Flyspray URL (live after DNS + SSL are configured)."
  value       = "https://${var.app_hostname}"
}

output "flyspray_conf_path" {
  description = "Local path to the generated backup flyspray.conf.php."
  value       = "${path.module}/output/flyspray.conf.php"
}

output "setup_ssl_path" {
  description = "Local path to the generated setup_ssl.sh."
  value       = "${path.module}/output/setup_ssl.sh"
}

output "next_steps" {
  description = "Post-apply checklist."
  value       = <<-EOT

    ---- NEXT STEPS (in order) ----

    Note: Flyspray and flyspray.conf.php are automatically installed and
    configured on the Lightsail instance on first boot via user_data.

    1. Create GoDaddy DNS A record:
         Name:  ${split(".", var.app_hostname)[0]}
         Value: ${aws_lightsail_static_ip.flyspray.ip_address}
         TTL:   600

    2. Run the DB import (loads dump from S3 into managed PostgreSQL):
         cd terraform/
         ./scripts/import_db.sh

    3. Wait for DNS propagation:
         dig +short ${var.app_hostname}   # should return ${aws_lightsail_static_ip.flyspray.ip_address}

    4. Provision SSL (Let's Encrypt):
         output/setup_ssl.sh

    5. Open https://${var.app_hostname}

    To tear everything down:
         terraform destroy
  EOT
}