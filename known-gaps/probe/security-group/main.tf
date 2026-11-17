terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
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

resource "aws_vpc" "probe" {
  cidr_block = "10.43.0.0/16"
}

resource "aws_security_group" "probe" {
  name   = "probe${var.suffix}"
  vpc_id = aws_vpc.probe.id
}
