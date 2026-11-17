# FlySpray PHP app on AWS Lightsail with Docker

> Historical AI-generated proposal, not deployment instructions. Several claims
> and commands below are incorrect or unsafe, including static IP reuse by
> containers, the `latest` Lightsail image reference, the `NO_SOURCE` build,
> certificate setup, and persistent attachments. Follow [README.md](README.md)
> for the current implementation and migration procedure instead.

This describes a transition from AWS Lightsail instances to containers, given 
a start on Terraform and scripts to build using an AWS LAMP blueprint.  

We use GoDaddy for a custom domain (a subdomain) and are working to prevent having
to update the DNS everytime we retry a deployment, so the IP address needs to be saved. 

We added this to main.tf to prevent IP address from being destroyed:

```
resource "aws_lightsail_static_ip" "flyspray" {
  name = local.static_ip_name

  lifecycle {
    prevent_destroy = true
  }
}
```

And then destroy the instance version as follows, but that may need to change


**Step 1 — Detach the static IP first (before destroying the instance)**

```bash
terraform destroy \
  -target=aws_lightsail_static_ip_attachment.flyspray
```

**Step 2 — Destroy the instance, database, and dependent resources (NOT the static IP)**

```bash
terraform destroy \
  -target=null_resource.instance_auto_snapshot \
  -target=aws_lightsail_instance_public_ports.flyspray \
  -target=aws_lightsail_instance.flyspray \
  -target=aws_lightsail_database.flyspray
```

## The key files for this new containerized version: 

you need to create alongside your main.tfare:

    Dockerfile
    — PHP 8.2 + Apache + pgsql extensions
    docker-entrypoint.sh
    — substitutes DB credentials at container startup so no secrets are baked into the image
    flyspray.conf.php.tpl
    — your config as a template with ${DB_HOST}
    style placeholders
    buildspec.yml
    — the --platform linux/amd64
    line is what solves the Apple Silicon problem entirely

## Two things to note before you start:

- The  `aws_lightsail_container_service_deployment_version` resource in the main.tf 
references :flyspray-containers.flyspray.latest as the image name — 
this is the name Lightsail assigns after you run push-container-image

- You will need to run that CLI command once first, then terraform apply 
  again to wire up the deployment. The CLI Commands list has the exact sequence listed

    GoDaddy DNS change — unlike the blueprint approach, the container service uses a CNAME (not an A record pointing to a static IP). You will need one DNS update at GoDaddy to point your domain to the Lightsail container endpoint, but after that it never changes again even if you redeploy.

## Architecture

Your new stack replaces the Lightsail blueprint instance with a fully managed container pipeline. AWS handles all OS patching — you only maintain your Dockerfile.

```
Your Mac (Apple Silicon M-series)
        |
        | git push  (just source code + Dockerfile)
        v
  AWS CodeBuild  ──────────────────────────────────────────────
        |  builds AMD64 image (--platform linux/amd64)         |
        |  no Docker needed on your Mac                        |
        v                                                       |
  Amazon ECR                                                    |
        |  stores versioned image                               |
        |  scans for CVEs on every push                        |
        v                                                       |
  Lightsail Container Service  <──────────────────────────────-+
        |  AWS manages OS + runtime                            
        |  you manage only your Dockerfile                     
        v                                                       
  Lightsail Managed PostgreSQL DB                              
        |  AWS manages DB engine + patches                     
        |  same terraform resource as before                   
        v                                                       
  GoDaddy DNS  -->  Lightsail container endpoint               
        (no static IP needed - container gets stable endpoint) 
```

| Azure Service                  | AWS Equivalent                  | Role                        |
|--------------------------------|---------------------------------|-----------------------------|
| Azure Container Registry       | Amazon ECR                      | Store Docker images         |
| ACR Tasks / Azure DevOps       | AWS CodeBuild                   | Build AMD64 images in cloud |
| Azure Web Apps (containers)    | Lightsail Container Service     | Run the container           |
| Azure Container Apps           | AWS App Runner / ECS Fargate    | If you outgrow Lightsail    |
| Azure Database for PostgreSQL  | Lightsail Managed PostgreSQL    | Managed database            |

## Rebuild workflow — order of operations


```
# ── BEFORE YOU START ──────────────────────────────────────────
# 1. Dump the existing database (from the instance, DB is private)
ssh -i ~/your-key.pem admin@<static-ip>
PGPASSWORD='<pass>' pg_dump \
  -h <db-endpoint> -p 5432 -U <app_user> -d <app_db> \
  --format=custom --no-owner --no-acl \
  -f /tmp/flyspray_dump.dump
# Copy dump to local machine
scp -i ~/your-key.pem admin@<static-ip>:/tmp/flyspray_dump.dump ~/flyspray_dump.dump

# ── TERRAFORM CHANGES ──────────────────────────────────────────
# 2. Update main.tf:
#    - Remove: aws_lightsail_instance, public_ports, static_ip,
#              static_ip_attachment, null_resource.instance_auto_snapshot
#              local_file.setup_ssl
#    - Add:    aws_ecr_repository, aws_codebuild_project,
#              aws_iam_role.codebuild, aws_lightsail_container_service
#    - Keep:   aws_lightsail_database (unchanged)

# 3. Destroy old instance resources (keep database for now)
terraform destroy -target=aws_lightsail_static_ip_attachment.flyspray
terraform destroy \
  -target=aws_lightsail_instance_public_ports.flyspray \
  -target=aws_lightsail_instance.flyspray \
  -target=aws_lightsail_static_ip.flyspray

# 4. Apply new infrastructure
terraform plan -out=tfplan
terraform apply tfplan

# ── BUILD & DEPLOY ─────────────────────────────────────────────
# 5. Trigger first container build
aws codebuild start-build --project-name flyspray-build --region us-east-2

# 6. After build completes, push image to Lightsail
aws lightsail push-container-image \
  --region us-east-2 \
  --service-name flyspray-containers \
  --label flyspray \
  --image <account-id>.dkr.ecr.us-east-2.amazonaws.com/flyspray:latest

# ── DATABASE ───────────────────────────────────────────────────
# 7. Create app user + database
./output/setup_db.sh

# 8. Restore backup
PGPASSWORD='<app_pass>' pg_restore \
  -h <new-db-endpoint> -p 5432 \
  -U <app_user> -d <app_db> \
  --no-owner --no-acl -v \
  flyspray_dump.dump

# ── DNS ────────────────────────────────────────────────────────
# 9. Point GoDaddy CNAME to Lightsail container endpoint
#    (get endpoint from: terraform output container_url)
#    SSL is automatic - no certbot needed
```

## Flyspray Dockerfile — PHP 8.2 + PostgreSQL + Apache

Place this file in the root of your project alongside your Flyspray source. Built for linux/amd64 by CodeBuild 

```Dockerfile
# syntax=docker/dockerfile:1
# ── Flyspray on PHP 8.2 + Apache + PostgreSQL ──────────────────
# Built for linux/amd64 by AWS CodeBuild.
# Never build this locally on Apple Silicon.
FROM php:8.2-apache

LABEL maintainer="your-email@example.com"
LABEL description="Flyspray bug tracker - PHP 8.2 + PostgreSQL"

# ── System dependencies ────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    libpq-dev \
    libpng-dev \
    libjpeg-dev \
    libzip-dev \
    zip \
    unzip \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# ── PHP extensions ─────────────────────────────────────────────
RUN docker-php-ext-configure gd --with-jpeg \
    && docker-php-ext-install \
        pdo \
        pdo_pgsql \
        pgsql \
        gd \
        zip \
        opcache

# ── Apache config ──────────────────────────────────────────────
RUN a2enmod rewrite
COPY apache-flyspray.conf /etc/apache2/sites-available/000-default.conf

# ── PHP config ─────────────────────────────────────────────────
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=60'; \
} > /usr/local/etc/php/conf.d/opcache.ini

# ── Flyspray application ───────────────────────────────────────
COPY flyspray/ /var/www/html/

# ── Config template (env vars injected at runtime) ─────────────
COPY flyspray.conf.php.tpl /var/www/html/flyspray.conf.php.tpl

# ── Entrypoint substitutes env vars into config ────────────────
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# ── Attachments directory ──────────────────────────────────────
RUN mkdir -p /var/www/html/attachments \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod -R 775 /var/www/html/attachments

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
```

## flyspray.conf.php template

Rename your existing flyspray.conf.php to this template. Environment variables are injected by the Lightsail container service at runtime — no secrets in the image

```PHP
<?php
# flyspray.conf.php.tpl
# Environment variables are substituted by docker-entrypoint.sh at startup.
# Never commit real credentials - this template has placeholders only.

[database]
dbtype   = pgsql
dbhost   = ${DB_HOST}
dbname   = ${DB_NAME}
dbuser   = ${DB_USER}
dbpass   = ${DB_PASS}
dbport   = ${DB_PORT}
dbprefix = flyspray_

[general]
base_url      = ${APP_BASE_URL}
attachmentdir = ./attachments
debuglevel    = 0
```

## docker-entrypoint.sh

Entrypoint script that substitutes environment variables into the config at container startup.

```
#!/usr/bin/env bash
# docker-entrypoint.sh
# Substitutes environment variables into flyspray.conf.php at container startup.
# Required env vars:
#   DB_HOST, DB_NAME, DB_USER, DB_PASS, DB_PORT, APP_BASE_URL
set -euo pipefail

CONF_TPL="/var/www/html/flyspray.conf.php.tpl"
CONF_OUT="/var/www/html/flyspray.conf.php"

echo "Generating flyspray.conf.php from template..."
envsubst < "$CONF_TPL" > "$CONF_OUT"
chown www-data:www-data "$CONF_OUT"
chmod 640 "$CONF_OUT"
echo "Config written to $CONF_OUT"

# Hand off to the CMD (apache2-foreground)
exec "$@"
```


## AWS CodeBuild buildspec — AMD64 build + ECR push + Lightsail deploy

Place this file in the root of your project. CodeBuild reads it automatically. The --platform linux/amd64 flag forces AMD64 regardless of the build host — solving the Apple Silicon problem entirely.

Buildspec
```
version: 0.2
# buildspec.yml - place in project root alongside Dockerfile
# CodeBuild reads this automatically.
# Builds AMD64 image regardless of build host - solves Apple Silicon problem.

env:
  variables:
    IMAGE_TAG: latest
    LIGHTSAIL_SERVICE: flyspray-containers
    LIGHTSAIL_LABEL: flyspray
    REGION: us-east-2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $REGION
          | docker login --username AWS --password-stdin $ECR_REPO_URI
      - IMAGE_URI=$ECR_REPO_URI:$IMAGE_TAG
      - echo Image will be tagged as $IMAGE_URI

  build:
    commands:
      - echo Building AMD64 image...
      - docker buildx create --use --name multiarch-builder
      - docker buildx build
          --platform linux/amd64
          --tag $IMAGE_URI
          --push
          .
      - echo Build complete.

  post_build:
    commands:
      - echo Pushing image to Lightsail container service...
      - aws lightsail push-container-image
          --region $REGION
          --service-name $LIGHTSAIL_SERVICE
          --label $LIGHTSAIL_LABEL
          --image $IMAGE_URI
      - echo Deployment complete.
      - echo $IMAGE_URI > image_uri.txt

artifacts:
  files:
    - image_uri.txt

cache:
  paths:
    - /root/.docker/**/*
```


----------------------
## Terraform CHANGES AND NEW MODULES

### Terraform — resources to REMOVE

remove these from the main script, leaving the rest intact

then look at the additional TF code, perhaps put them in separate files

```
# ── REMOVE these resources from main.tf ───────────────────────
# They are replaced by the container service.

# REMOVE - no longer needed with container service:
# resource "aws_lightsail_instance" "flyspray" { ... }
# resource "aws_lightsail_instance_public_ports" "flyspray" { ... }
# resource "aws_lightsail_static_ip" "flyspray" { ... }
# resource "aws_lightsail_static_ip_attachment" "flyspray" { ... }
# resource "null_resource" "instance_auto_snapshot" { ... }
# resource "local_file" "setup_ssl" { ... }   <- certbot not needed

# KEEP these resources:
# resource "aws_lightsail_database" "flyspray" { ... }  <- unchanged
# resource "local_file" "setup_db" { ... }              <- still needed

# ADD these new resources:
# resource "aws_ecr_repository" "flyspray" { ... }
# resource "aws_ecr_lifecycle_policy" "flyspray" { ... }
# resource "aws_iam_role" "codebuild" { ... }
# resource "aws_iam_role_policy" "codebuild" { ... }
# resource "aws_codebuild_project" "flyspray" { ... }
# resource "aws_lightsail_container_service" "flyspray" { ... }
# resource "aws_lightsail_container_service_deployment_version" "flyspray" { ... }
```

------------------
### ECR repository



`aws_ecr.tf` 

```terraform
# ── Amazon ECR - container image registry ─────────────────────
resource "aws_ecr_repository" "flyspray" {
  name                 = "flyspray"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true    # scans every image for CVEs automatically
  }

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }
}

# Auto-delete old images - keep only the last 5 to control storage costs
resource "aws_ecr_lifecycle_policy" "flyspray" {
  repository = aws_ecr_repository.flyspray.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_repository_url" {
  value = aws_ecr_repository.flyspray.repository_url
}
```

--------------------------------------------
### Terraform — CodeBuild project + IAM role

`aws_codebuild.tf`

```terraform
# ── IAM role for CodeBuild ─────────────────────────────────────
resource "aws_iam_role" "codebuild" {
  name = "flyspray-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR - push images
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        # Lightsail - push container image
        Effect   = "Allow"
        Action   = ["lightsail:*"]
        Resource = "*"
      },
      {
        # CloudWatch Logs - build logs
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# ── CodeBuild project ──────────────────────────────────────────
resource "aws_codebuild_project" "flyspray" {
  name          = "flyspray-build"
  description   = "Builds Flyspray AMD64 Docker image and pushes to ECR + Lightsail"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec.yml")
    # To connect to GitHub instead, replace with:
    # type     = "GITHUB"
    # location = "https://github.com/your-org/flyspray"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true    # required for docker buildx

    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.flyspray.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/flyspray"
      stream_name = "build"
    }
  }

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }
}
```



-------------------------------------------
### Terraform — Lightsail container service

aws_ls_container.tf

```terraform
# ── Lightsail container service ───────────────────────────────
resource "aws_lightsail_container_service" "flyspray" {
  name  = "flyspray-containers"
  power = "nano"    # nano=0.25vCPU/512MB, micro=0.5vCPU/1GB
                    # small=1vCPU/2GB, medium=2vCPU/4GB
  scale = 1

  # Custom domain + automatic SSL (no certbot needed)
  public_domain_names {
    certificate {
      certificate_name = "flyspray-cert"
      domain_names     = [var.app_hostname]
    }
  }

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }
}

# ── Container deployment (run after push-container-image) ──────
resource "aws_lightsail_container_service_deployment_version" "flyspray" {
  service_name = aws_lightsail_container_service.flyspray.name

  container {
    container_name = "flyspray"
    image          = ":flyspray-containers.flyspray.latest"

    # Environment variables injected at runtime - no secrets in image
    environment = {
      DB_HOST      = aws_lightsail_database.flyspray.master_endpoint_address
      DB_PORT      = tostring(aws_lightsail_database.flyspray.master_endpoint_port)
      DB_NAME      = var.app_db
      DB_USER      = var.app_user
      DB_PASS      = var.app_password    # use var, not hardcoded
      APP_BASE_URL = "https://${var.app_hostname}"
    }

    ports = {
      "80" = "HTTP"
    }
  }

  public_endpoint {
    container_name = "flyspray"
    container_port = 80

    health_check {
      healthy_threshold   = 2
      unhealthy_threshold = 2
      timeout_seconds     = 5
      interval_seconds    = 10
      path                = "/"
      success_codes       = "200-499"
    }
  }
}

output "container_url" {
  value       = aws_lightsail_container_service.flyspray.url
  description = "Point your GoDaddy CNAME to this endpoint"
}

```

-----------------------------------------------------
### Terraform — Lightsail managed PostgreSQL database 
(unchanged)

aws_ls_pg.tf
```terraform 
# ── Lightsail managed PostgreSQL - UNCHANGED from your current main.tf ──
# Keep this resource exactly as it is.
# The container service connects to it via environment variables.
resource "aws_lightsail_database" "flyspray" {
  relational_database_name = var.db_instance_name
  blueprint_id             = "postgres_16"
  bundle_id                = var.db_bundle_id
  master_database_name     = "postgres"
  master_username          = "dbmaster"
  master_password          = var.db_master_password
  availability_zone        = "${var.region}a"
  publicly_accessible      = false    # container is in same private network
  apply_immediately        = true

  tags = {
    Project     = "flyspray"
    Environment = var.environment
  }
}
```


==================
## Commands to run
==================

### Push container image to Lightsail

Run this after CodeBuild pushes the image to ECR. Can also be added as the final post_build step in buildspec.yml to make the pipeline fully automatic.

```bash
# ── Push container image to Lightsail ─────────────────────────
# Run this after CodeBuild pushes the image to ECR.
# This is also added as the final post_build step in buildspec.yml
# so the full pipeline runs automatically on every build.

# Step 1 - authenticate Docker to ECR
aws ecr get-login-password --region us-east-2 \
  | docker login \
      --username AWS \
      --password-stdin \
      <account-id>.dkr.ecr.us-east-2.amazonaws.com

# Step 2 - push the ECR image into Lightsail
aws lightsail push-container-image \
  --region us-east-2 \
  --service-name flyspray-containers \
  --label flyspray \
  --image <account-id>.dkr.ecr.us-east-2.amazonaws.com/flyspray:latest

# The command returns the Lightsail image name, e.g.:
#   :flyspray-containers.flyspray.1
# Use that value in the aws_lightsail_container_service_deployment_version
# resource's image field in main.tf.
```


### Trigger a CodeBuild build manually

`aws_ecrbuild.sh`

```bash
# ── Trigger a CodeBuild build manually ────────────────────────
# Use this to kick off a build from your Mac without needing Docker.

# Start the build
aws codebuild start-build \
  --project-name flyspray-build \
  --region us-east-2

# Watch build status
aws codebuild list-builds-for-project \
  --project-name flyspray-build \
  --region us-east-2

# Get build logs (replace BUILD_ID with the id from above)
aws codebuild batch-get-builds \
  --ids <BUILD_ID> \
  --region us-east-2 \
  --query 'builds[0].{status:buildStatus,phase:currentPhase,logs:logs.deepLink}'

# Or watch logs live in CloudWatch
# https://us-east-2.console.aws.amazon.com/cloudwatch/home#logsV2:log-groups/log-group/$252Faws$252Fcodebuild$252Fflyspray
```



## Verify the running container

`aws_ecr_verify.sh`

```bash
# ── Verify the running container service ──────────────────────

# Check container service state
aws lightsail get-container-services \
  --service-name flyspray-containers \
  --region us-east-2 \
  --query 'containerServices[0].{state:state,url:url,power:power,scale:scale}'

# Check current deployment
aws lightsail get-container-service-deployments \
  --service-name flyspray-containers \
  --region us-east-2

# Get the public endpoint URL (point GoDaddy CNAME here)
terraform output container_url

# Check container logs
aws lightsail get-container-log \
  --service-name flyspray-containers \
  --container-name flyspray \
  --region us-east-2

```


### ── Database setup process (same as before, unchanged) ────────────────

```bash
# Step 1 - create app user + database
./output/setup_db.sh

# Step 2 - restore your pg_dump backup
PGPASSWORD='<app_pass>' pg_restore \
  -h <db-endpoint> \
  -p 5432 \
  -U <app_user> \
  -d <app_db> \
  --no-owner \
  --no-acl \
  -v \
  flyspray_dump.dump

# Step 3 - verify the restore
PGPASSWORD='<app_pass>' psql \
  -h <db-endpoint> -p 5432 \
  -U <app_user> -d <app_db> \
  -c "SELECT COUNT(*) FROM flyspray_tasks;"
```