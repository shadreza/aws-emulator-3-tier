output "site_url" {
  value = "https://${aws_cloudfront_distribution.web.domain_name}"
}

output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}

output "table_name" {
  value = aws_dynamodb_table.notes.name
}
