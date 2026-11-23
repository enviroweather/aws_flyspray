output "container_service_name" {
  description = "Name of the Lightsail container service."
  value       = aws_lightsail_container_service.flyspray.name
}

output "container_url" {
  description = "Service URL; use its hostname as the custom-domain CNAME target."
  value       = aws_lightsail_container_service.flyspray.url
}

output "certificate_validation_records" {
  description = "DNS records required to validate the Lightsail certificate."
  value       = aws_lightsail_certificate.flyspray.domain_validation_options
}

output "ecr_repository_url" {
  description = "ECR repository CodeBuild publishes the Flyspray image to."
  value       = aws_ecr_repository.flyspray.repository_url
}

output "codebuild_project_name" {
  description = "CodeBuild project name; trigger a build with `aws codebuild start-build`."
  value       = aws_codebuild_project.flyspray.name
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

output "app_db" {
  description = "Flyspray database name."
  value       = var.app_db
}

output "app_user" {
  description = "Flyspray database user."
  value       = var.app_user
}

output "region" {
  description = "AWS region deployed to."
  value       = var.region
}

output "s3_bucket" {
  description = "S3 bucket containing the SQL dump."
  value       = var.s3_bucket
}

output "s3_dump_key" {
  description = "S3 object key for the SQL dump."
  value       = var.s3_dump_key
}