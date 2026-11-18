mock_provider "aws" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "archive" {}

variables {
  app_hostname       = "flyspray.example.com"
  db_master_password = "test-password"
  app_password       = "test-password"
}

run "service_before_image" {
  command = plan

  assert {
    condition     = length(aws_lightsail_container_service_deployment_version.flyspray) == 0
    error_message = "No deployment should be created before deploy_flyspray is set."
  }
}

run "deployment_with_image" {
  command = plan

  variables {
    deploy_flyspray      = true
    cookie_salt          = "a-very-long-random-cookie-salt"
    enable_custom_domain = true
  }

  override_data {
    target = data.aws_ecr_image.flyspray[0]
    values = {
      image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000de"
    }
  }

  assert {
    condition     = length(aws_lightsail_container_service_deployment_version.flyspray) == 1
    error_message = "Enabling deploy_flyspray should create a deployment."
  }
}

run "deployment_requires_cookie_salt" {
  command = plan

  variables {
    deploy_flyspray = true
  }

  override_data {
    target = data.aws_ecr_image.flyspray[0]
    values = {
      image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000de"
    }
  }

  expect_failures = [aws_lightsail_container_service_deployment_version.flyspray]
}
