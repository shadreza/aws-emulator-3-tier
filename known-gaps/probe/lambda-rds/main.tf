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

# RDS for MySQL, and a Lambda function that opens a socket to it. No VPC
# config on the function: the gap this checks (G8) was found without one.
resource "aws_db_instance" "probe" {
  identifier          = "probe-lambda-mysql${var.suffix}"
  engine              = "mysql"
  engine_version      = "8.0"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  db_name             = "probe"
  username            = "app"
  password            = "probe-only-local-1"
  skip_final_snapshot = true
}

resource "aws_iam_role" "fn" {
  name = "probe-lambda-rds${var.suffix}"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

# run.sh builds the zip: handler.py plus ../rds-mysql/query.py, standard
# library only, so nothing is downloaded.
resource "aws_lambda_function" "probe" {
  function_name    = "probe-lambda-rds${var.suffix}"
  role             = aws_iam_role.fn.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = "${path.module}/build/fn.zip"
  source_code_hash = filebase64sha256("${path.module}/build/fn.zip")
  timeout          = 30
}

output "function" { value = aws_lambda_function.probe.function_name }
output "address" { value = aws_db_instance.probe.address }
output "port" { value = aws_db_instance.probe.port }
