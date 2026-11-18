variable "container_service_name" {
  description = "Name of the long-lived Lightsail container service."
  type        = string
  default     = "flyspray-containers"
}

variable "container_power" {
  description = "Lightsail container service power."
  type        = string
  default     = "nano"
}

variable "container_scale" {
  description = "Number of nodes; limited to one because Flyspray sessions are not shared."
  type        = number
  default     = 1

  validation {
    condition     = var.container_scale == 1
    error_message = "Only one node is supported until sessions and files use shared durable storage."
  }
}

variable "image_tag" {
  description = "ECR image tag that CodeBuild publishes; Lightsail deploys this tag's current digest."
  type        = string
  default     = "latest"
}

variable "deploy_flyspray" {
  description = "Set true only after CodeBuild has successfully pushed image_tag at least once."
  type        = bool
  default     = false
}

variable "db_prefix" {
  description = "Flyspray database table prefix; must match the existing database's prefix."
  type        = string
  default     = "flyspray_"
}

variable "cookie_salt" {
  description = "Flyspray session cookie salt. SECRET — set via TF_VAR_cookie_salt. Changing it invalidates sessions."
  type        = string
  sensitive   = true
  default     = ""
}

variable "syntax_plugin" {
  description = "Flyspray syntax_plugin setting (e.g. dokuwiki, html, or empty for none)."
  type        = string
  default     = ""
}

variable "enable_custom_domain" {
  description = "Attach the certificate only after its DNS validation succeeds."
  type        = bool
  default     = false
}

resource "aws_lightsail_certificate" "flyspray" {
  name        = "${var.container_service_name}-cert"
  domain_name = var.app_hostname
}

resource "aws_lightsail_container_service" "flyspray" {
  name  = var.container_service_name
  power = var.container_power
  scale = var.container_scale

  # Lets the service pull directly from the private ECR repo without pushing
  # images through lightsailctl or storing a registry credential anywhere.
  private_registry_access {
    ecr_image_puller_role {
      is_active = true
    }
  }

  dynamic "public_domain_names" {
    for_each = var.enable_custom_domain ? [1] : []
    content {
      certificate {
        certificate_name = aws_lightsail_certificate.flyspray.name
        domain_names     = [var.app_hostname]
      }
    }
  }

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Grants the service's pull role read access to the repo CodeBuild publishes to.
resource "aws_ecr_repository_policy" "flyspray" {
  repository = aws_ecr_repository.flyspray.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LightsailImagePull"
      Effect    = "Allow"
      Principal = { AWS = aws_lightsail_container_service.flyspray.private_registry_access[0].ecr_image_puller_role[0].principal_arn }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    }]
  })
}

# Resolved only when deploying, so earlier stages don't require an image to exist yet.
data "aws_ecr_image" "flyspray" {
  count           = var.deploy_flyspray ? 1 : 0
  repository_name = aws_ecr_repository.flyspray.name
  image_tag       = var.image_tag
  depends_on      = [aws_ecr_repository_policy.flyspray]
}

resource "aws_lightsail_container_service_deployment_version" "flyspray" {
  count        = var.deploy_flyspray ? 1 : 0
  service_name = aws_lightsail_container_service.flyspray.name

  container {
    container_name = "flyspray"
    # Pinning to the digest (not the mutable tag) so a plan picks up every new
    # CodeBuild push automatically, without bumping image_tag each time.
    image = "${aws_ecr_repository.flyspray.repository_url}@${data.aws_ecr_image.flyspray[0].image_digest}"

    environment = {
      DB_HOST       = aws_lightsail_database.flyspray.master_endpoint_address
      DB_PORT       = tostring(aws_lightsail_database.flyspray.master_endpoint_port)
      DB_NAME       = var.app_db
      DB_USER       = var.app_user
      DB_PASS       = var.app_password
      DB_PREFIX     = var.db_prefix
      APP_BASE_URL  = "https://${var.app_hostname}/"
      COOKIE_SALT   = var.cookie_salt
      SYNTAX_PLUGIN = var.syntax_plugin
    }
    ports = { "80" = "HTTP" }
  }

  public_endpoint {
    container_name = "flyspray"
    container_port = 80
    health_check {
      path                = "/health.txt"
      success_codes       = "200"
      healthy_threshold   = 2
      unhealthy_threshold = 2
      timeout_seconds     = 5
      interval_seconds    = 10
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.cookie_salt) >= 16
      error_message = "Set TF_VAR_cookie_salt to a random string of at least 16 characters before deploying."
    }
  }
}
