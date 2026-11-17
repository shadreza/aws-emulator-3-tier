terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region            = "us-east-1"
  s3_use_path_style = true
}

# A suffix per run, so a check that failed to clean up doesn't block the next
# run on the same emulator.
variable "suffix" {
  type    = string
  default = ""
}

resource "aws_s3_bucket" "probe" {
  bucket_prefix = "probe-"
  force_destroy = true
}
