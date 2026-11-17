# Tier 1: a private S3 bucket served by CloudFront. /api/* goes to the HTTP API,
# so the page and the API share one origin and need no CORS.
resource "aws_s3_bucket" "web" {
  bucket_prefix = "${var.name}-web-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "web" {
  for_each = {
    "index.html" = "text/html"
    "app.js"     = "text/javascript"
    "style.css"  = "text/css"
  }
  bucket       = aws_s3_bucket.web.id
  key          = each.key
  source       = "${path.module}/../web/${each.key}"
  etag         = filemd5("${path.module}/../web/${each.key}")
  content_type = each.value
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.name}-web"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  # The API's URL is https://<id>.execute-api.<region>.amazonaws.com on AWS and
  # https://127.0.0.1:<port>/_aws/execute-api/<id> on the emulator. Split it so
  # CloudFront gets a host, a port and a path in both places.
  api_url  = regex("^https://([^/:]+)(?::([0-9]+))?(/.*)?$", aws_apigatewayv2_api.api.api_endpoint)
  api_host = local.api_url[0]
  api_port = coalesce(local.api_url[1], "443")
  api_path = coalesce(local.api_url[2], "")
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  comment             = "${var.name} frontend"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "web"
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  origin {
    origin_id   = "api"
    domain_name = local.api_host
    origin_path = local.api_path

    custom_origin_config {
      http_port              = 80
      https_port             = tonumber(local.api_port)
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "web"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Only this distribution may read the bucket.
data "aws_iam_policy_document" "web" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket     = aws_s3_bucket.web.id
  policy     = data.aws_iam_policy_document.web.json
  depends_on = [aws_s3_bucket_public_access_block.web]
}
