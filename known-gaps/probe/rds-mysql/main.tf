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

# RDS for MySQL, the way an ECS app would use it. The password is a probe
# value for this local emulator only; it never reaches AWS.
resource "aws_db_instance" "probe" {
  identifier          = "probe-mysql${var.suffix}"
  engine              = "mysql"
  engine_version      = "8.0"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  db_name             = "probe"
  username            = "app"
  password            = "probe-only-local-1"
  skip_final_snapshot = true
}

output "address" { value = aws_db_instance.probe.address }
output "port" { value = aws_db_instance.probe.port }
