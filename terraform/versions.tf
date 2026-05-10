terraform {
  required_version = ">= 1.3.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.31.0, < 8.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.7.1, < 3.0.0"
    }
  }
}
