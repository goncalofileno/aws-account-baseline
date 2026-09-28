# modules/tags has no resources or provider, so these runs need no mock_provider.

run "valid_input_produces_the_exact_tag_map" {
  command = plan

  module {
    source = "./modules/tags"
  }

  variables {
    component   = "web"
    environment = "prod"
    managed_by  = "pulumi"
    repository  = "github.com/goncalofileno/cv-site"
  }

  assert {
    condition = output.tags == {
      Project     = "cv-site"
      Component   = "web"
      Environment = "prod"
      ManagedBy   = "pulumi"
      Repository  = "github.com/goncalofileno/cv-site"
      Owner       = "goncalo-fileno"
    }
    error_message = "tags output must contain exactly these six keys and values."
  }
}

run "rejects_invalid_component" {
  command = plan

  module {
    source = "./modules/tags"
  }

  variables {
    component   = "bogus"
    environment = "prod"
    managed_by  = "terraform"
    repository  = "github.com/goncalofileno/cv-site"
  }

  expect_failures = [var.component]
}

run "rejects_invalid_environment" {
  command = plan

  module {
    source = "./modules/tags"
  }

  variables {
    component   = "web"
    environment = "staging"
    managed_by  = "terraform"
    repository  = "github.com/goncalofileno/cv-site"
  }

  expect_failures = [var.environment]
}

run "rejects_invalid_managed_by" {
  command = plan

  module {
    source = "./modules/tags"
  }

  variables {
    component   = "web"
    environment = "prod"
    managed_by  = "cloudformation"
    repository  = "github.com/goncalofileno/cv-site"
  }

  expect_failures = [var.managed_by]
}

run "rejects_invalid_repository" {
  command = plan

  module {
    source = "./modules/tags"
  }

  variables {
    component   = "web"
    environment = "prod"
    managed_by  = "terraform"
    repository  = "gitlab.com/goncalofileno/cv-site"
  }

  expect_failures = [var.repository]
}
