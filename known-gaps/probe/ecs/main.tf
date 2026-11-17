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

  map_public_ip_on_launch = true
}

# A public subnet: a route to an internet gateway. The emulator checks the
# task's network placement, and a subnet with no route to the registry gets
# CannotPullContainerError, as on AWS.
resource "aws_internet_gateway" "probe" {
  vpc_id = aws_vpc.probe.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.probe.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.probe.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.probe[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_ecs_cluster" "probe" {
  name = "probe${var.suffix}"
}

# The task's container prints 6 * 7 through the shell. If the image really
# runs, the log says "ran-42". Fargate needs an execution role to write logs.
resource "aws_iam_role" "exec" {
  name = "probe-ecs-exec${var.suffix}"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "exec" {
  role = aws_iam_role.exec.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }]
  })
}

resource "aws_cloudwatch_log_group" "probe" {
  name = "/probe/ecs${var.suffix}"
}

resource "aws_ecs_task_definition" "probe" {
  family                   = "probe${var.suffix}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec.arn
  container_definitions = jsonencode([{
    name      = "probe"
    image     = "public.ecr.aws/docker/library/busybox:latest"
    essential = true
    command   = ["sh", "-c", "echo ran-$((6*7)); uname -s"]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.probe.name
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "probe"
      }
    }
  }])
}

output "cluster" { value = aws_ecs_cluster.probe.name }
output "task_definition" { value = aws_ecs_task_definition.probe.arn }
output "subnet" { value = aws_subnet.probe[0].id }
output "log_group" { value = aws_cloudwatch_log_group.probe.name }
