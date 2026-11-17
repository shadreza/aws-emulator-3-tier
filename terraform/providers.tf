terraform {
  required_version = ">= 1.6"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.100" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

# No endpoint and no keys in this file. The same code deploys to the emulator
# or to a real account; the shell decides which (see scripts/emulator-env.sh).
provider "aws" {
  region            = var.region
  s3_use_path_style = true

  default_tags {
    tags = { project = var.name, managed_by = "terraform" }
  }
}
