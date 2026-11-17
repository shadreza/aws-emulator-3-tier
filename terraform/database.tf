# Tier 3: a DynamoDB table. The app reaches it with its IAM role, so there is
# no database password anywhere: not in code, not in .env, not in the state.
resource "aws_dynamodb_table" "notes" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "id"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  # AWS Emulator 1.0.322 reports on-demand throughput as -1, which Terraform
  # reads as drift on every plan. Harmless to keep on real AWS.
  lifecycle {
    ignore_changes = [on_demand_throughput]
  }
}
