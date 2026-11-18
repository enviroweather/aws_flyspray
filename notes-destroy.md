## Destroying Terraform 

*These instructions are for Lightsail instance and may not 
work for a containerized version*

```
Important limitations: Lightsail containers cannot use the existing static IP. The IP is retained, but a one-time DNS change is required. The container service must then be retained to keep its generated hostname. Attachments and avatars are not yet durable, so this is not ready for production migration where those files are needed.
```

see the main [README.md](./README.md)

this is in main.tf to prevent IP address from being destroyed (but it may not 
stay as we move to containerization)

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