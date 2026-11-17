## Destroying Terraform 



this is in main.tf to prevent IP address from being destroyed:

```
resource "aws_lightsail_static_ip" "flyspray" {
  name = local.static_ip_name

  lifecycle {
    prevent_destroy = true
  }
}

```

How can you destroy all the things, but keep the ip address?

**Step 1 — Detach the static IP first (before destroying the instance)**
terraform destroy \
  -target=aws_lightsail_static_ip_attachment.flyspray

**Step 2 — Destroy the instance, database, and dependent resources (NOT the static IP)**

terraform destroy \
  -target=null_resource.instance_auto_snapshot \
  -target=aws_lightsail_instance_public_ports.flyspray \
  -target=aws_lightsail_instance.flyspray \
  -target=aws_lightsail_database.flyspray


TODO: update cleanup_flyspray.sh