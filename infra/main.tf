locals {
  apex_domain = var.domain_name
  www_domain  = "www.${var.domain_name}"

  # Avoid dots in S3 bucket names when using HTTPS endpoints; use hyphens.
  bucket_name = "${replace(var.domain_name, ".", "-")}-site"
}

# Fetch the existing Route 53 hosted zone you already created
data "aws_route53_zone" "this" {
  name         = "${var.domain_name}."
  private_zone = false
}

############################################
# ACM certificate (must be in us-east-1)
############################################

resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = local.apex_domain
  validation_method = "DNS"

  subject_alternative_names = var.enable_www ? [local.www_domain] : []

  # CloudFront requires a valid cert at all times
  # this creates and adds the new cert and then destorys the old cert
  # now there is zero down-time
  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# Create DNS validation records in Route 53
resource "aws_route53_record" "cert_validation" {

  # This will run 2x (myanpatel.dev & www.myanpatel.dev)
  /* 
    {
        "myanpatel.dev" = {
            name  = "_abc123.example.com."
            type  = "CNAME"
            value = "_xyz456.acm-validations.aws."
        }
        "www.myanpatel.dev" = {
            name  = "_def789.www.example.com."
            type  = "CNAME"
            value = "_pqr111.acm-validations.aws."
        }
    } 
    */

  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

############################################
# S3 bucket (private) for site content
############################################

resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

############################################
# CloudFront distribution with OAC
############################################

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${replace(var.domain_name, ".", "-")}-oac"
  description                       = "OAC for private S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "rewrite_to_index" {
  name    = "${replace(var.domain_name, ".", "-")}-rewrite-index"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite /path/ -> /path/index.html and redirect /path -> /path/"
  publish = true

  code = <<EOF
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // If the URI has no file extension and doesn't end with '/',
  // redirect to add the trailing slash (e.g. /projects -> /projects/)
  var hasExtension = uri.includes('.') && uri.lastIndexOf('.') > uri.lastIndexOf('/');
  if (!hasExtension && !uri.endsWith('/')) {
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: {
        location: { value: uri + '/' }
      }
    };
  }

  // If it ends with '/', serve index.html (e.g. /projects/ -> /projects/index.html)
  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
  }

  return request;
}
EOF
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Portfolio site for ${var.domain_name}"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # cheapest/UK+EU+US edge set

  aliases = var.enable_www ? [local.apex_domain, local.www_domain] : [local.apex_domain]

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-origin-${aws_s3_bucket.site.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-origin-${aws_s3_bucket.site.id}"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    compress = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite_to_index.arn
    }
  }

  # Optional: if your Astro build generates /404.html, this improves SPA-ish routing
  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = var.tags

  depends_on = [aws_acm_certificate_validation.site]
}

############################################
# DNS records (A + AAAA) -> CloudFront
############################################

resource "aws_route53_record" "apex_a" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.apex_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex_aaaa" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.apex_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_a" {
  count   = var.enable_www ? 1 : 0
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.www_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_aaaa" {
  count   = var.enable_www ? 1 : 0
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.www_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

############################################
# S3 bucket policy: allow only CloudFront
############################################

data "aws_iam_policy_document" "site_bucket_policy" {
  statement {
    sid     = "AllowCloudFrontRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket_policy.json
}

/*

Full Pipeline:

1. User goes to myanpatel.dev
2. Route 53 resolves it to CloudFront
3. CloudFront serves cached files if it has them
4. If not cached, CloudFront fetches from S3 using OAC signed request
5. S3 allows the request because it matches the bucket policy
6. CloudFront returns the content over HTTPS using your ACM cert

*/