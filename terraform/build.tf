data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# ECR — stores the image CodeBuild publishes; Lightsail pulls from it directly
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "flyspray" {
  name                 = "${var.container_service_name}-flyspray"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

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

# ---------------------------------------------------------------------------
# Build source — the container/ folder is zipped and uploaded for CodeBuild.
# No local Docker or GitHub connection is required to build the image.
# ---------------------------------------------------------------------------
data "archive_file" "container_source" {
  type        = "zip"
  source_dir  = "${path.module}/../container"
  output_path = "${path.module}/.build/container-source.zip"
}

resource "aws_s3_bucket" "build_source" {
  bucket        = "${var.container_service_name}-build-src-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "build_source" {
  bucket                  = aws_s3_bucket.build_source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "build_source" {
  bucket = aws_s3_bucket.build_source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "container_source" {
  bucket = aws_s3_bucket.build_source.id
  key    = "container-source/${data.archive_file.container_source.output_sha}.zip"
  source = data.archive_file.container_source.output_path
  etag   = data.archive_file.container_source.output_md5
}

# ---------------------------------------------------------------------------
# CodeBuild — builds the image on an AWS-managed x86_64 host, so an Apple
# Silicon workstation never needs to build or even install Docker locally.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "codebuild" {
  name = "${var.container_service_name}-codebuild"

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
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.flyspray.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.container_service_name}-build*"
      },
      {
        Sid      = "SourceRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.build_source.arn}/*"
      },
    ]
  })
}

locals {
  buildspec = <<-YAML
    version: 0.2
    phases:
      pre_build:
        commands:
          - aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | docker login --username AWS --password-stdin "$ECR_REPO_URI"
      build:
        commands:
          - docker build --build-arg "FLYSPRAY_VERSION=$FLYSPRAY_VERSION" --build-arg "INCLUDE_SETUP=$INCLUDE_SETUP" -t "$ECR_REPO_URI:$IMAGE_TAG" .
      post_build:
        commands:
          - docker push "$ECR_REPO_URI:$IMAGE_TAG"
  YAML
}

resource "aws_codebuild_project" "flyspray" {
  name          = "${var.container_service_name}-build"
  description   = "Builds the Flyspray image on an x86_64 host and pushes it to ECR."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.build_source.id}/${aws_s3_object.container_source.key}"
    buildspec = local.buildspec
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for `docker build`/`docker push`

    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.flyspray.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = var.image_tag
    }
    environment_variable {
      name  = "FLYSPRAY_VERSION"
      value = var.flyspray_version
    }
    environment_variable {
      name  = "INCLUDE_SETUP"
      value = tostring(var.include_setup)
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.container_service_name}-build"
    }
  }

}
