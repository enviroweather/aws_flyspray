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
  description = "Local path to the generated flyspray.conf.php."
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

    1. Create GoDaddy DNS A record:
         Name:  ${split(".", var.app_hostname)[0]}
         Value: ${aws_lightsail_static_ip.flyspray.ip_address}
         TTL:   600

    2. SSH in and install Flyspray into the web root:
         aws lightsail ssh --instance-name ${var.instance_name} --region ${var.region}

       On the instance:
         cd /opt/bitnami/apache/htdocs
         sudo wget https://github.com/flyspray/flyspray/releases/download/v1.0/flyspray-1.0.tar.gz
         sudo tar xzf flyspray-1.0.tar.gz
         sudo mv flyspray/* .
         sudo mv flyspray/.htaccess . 2>/dev/null || true
         sudo rm -rf flyspray flyspray-1.0.tar.gz

    3. Run the DB import:
         cd terraform/
         ./scripts/import_db.sh

    4. Copy flyspray.conf.php to the instance:
         scp output/flyspray.conf.php bitnami@${aws_lightsail_static_ip.flyspray.ip_address}:/tmp/
       On the instance:
         sudo mv /tmp/flyspray.conf.php /opt/bitnami/apache/htdocs/
         sudo chown -R bitnami:daemon /opt/bitnami/apache/htdocs
         sudo chmod -R 775 /opt/bitnami/apache/htdocs/attachments

    5. Wait for DNS propagation:
         dig +short ${var.app_hostname}   # should return ${aws_lightsail_static_ip.flyspray.ip_address}

    6. Provision SSL:
         output/setup_ssl.sh

    7. Open https://${var.app_hostname}

    To tear everything down:
         terraform destroy
  EOT
}