# static_ip.tf  — allocate ONCE, never destroy
resource "aws_lightsail_static_ip" "app_ip" {
  name = var.static_ip_name
}