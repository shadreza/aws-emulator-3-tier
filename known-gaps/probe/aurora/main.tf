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
  cidr_block = "10.42.0.0/16"
}

resource "aws_subnet" "probe" {
  count             = 2
  vpc_id            = aws_vpc.probe.id
  cidr_block        = "10.42.${count.index}.0/24"
  availability_zone = "us-east-1${["a", "b"][count.index]}"
}

resource "aws_db_subnet_group" "probe" {
  name       = "probe-db${var.suffix}"
  subnet_ids = aws_subnet.probe[*].id
}

resource "aws_rds_cluster" "probe" {
  cluster_identifier          = "probe-db${var.suffix}"
  engine                      = "aurora-postgresql"
  engine_mode                 = "provisioned"
  database_name               = "probe"
  master_username             = "app"
  manage_master_user_password = true
  enable_http_endpoint        = true
  db_subnet_group_name        = aws_db_subnet_group.probe.name
  skip_final_snapshot         = true

  serverlessv2_scaling_configuration {
    min_capacity = 0
    max_capacity = 1
  }
}
