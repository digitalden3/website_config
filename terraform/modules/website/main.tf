# Define local values for easy reference to important IDs and ARNs
locals {
  website_bucket_id = aws_s3_bucket.website_bucket.id
  ssl_cert_arn      = aws_acm_certificate.ssl_certificate.arn
}

# Data source to fetch the existing Route53 DNS zone information
data "aws_route53_zone" "dns_zone" {
    name = var.root_domain
    private_zone = false
}

# Resource to request an ACM SSL certificate for the given domain name and its subdomains
resource "aws_acm_certificate" "ssl_certificate" {
    domain_name = var.root_domain
    subject_alternative_names = ["*.${var.root_domain}"]
    validation_method = "DNS"
    lifecycle {
        create_before_destroy = true
    }
}

# ACM Certificate DNS validation record
# This resource is the DNS record that must be created to prove ownership of the domain
resource "aws_route53_record" "dns_validation" {
    allow_overwrite = true
    name            = tolist(aws_acm_certificate.ssl_certificate.domain_validation_options)[0].resource_record_name
    records         = [tolist(aws_acm_certificate.ssl_certificate.domain_validation_options)[0].resource_record_value]
    type            = tolist(aws_acm_certificate.ssl_certificate.domain_validation_options)[0].resource_record_type
    zone_id         = data.aws_route53_zone.dns_zone.zone_id
    ttl             = 60
}

# ACM Certificate validation resource
# This resource represents the validation of the ACM certificate using the DNS record
resource "aws_acm_certificate_validation" "ssl_validation" {
    certificate_arn         = local.ssl_cert_arn
    validation_record_fqdns = [aws_route53_record.dns_validation.fqdn]
}

# S3 bucket resource for website hosting
# This bucket will be used to store the website files
resource "aws_s3_bucket" "website_bucket" {
  bucket = var.root_domain

  tags = {
    Name = var.root_domain
  }
}

# S3 bucket website configuration
# Configures the bucket to act as a website
resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = local.website_bucket_id

  index_document {
    suffix = "index.html"
  }
}

# S3 bucket policy
# Defines who can access the S3 bucket and what actions they can perform
resource "aws_s3_bucket_policy" "website_bucket_policy" {
  bucket = local.website_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::${aws_s3_bucket.website_bucket.bucket}/*"
        Condition = {
          StringEquals = {
            "aws:SourceArn": aws_cloudfront_distribution.website_distribution.arn
          }
        }
      }
    ]
  })
}

# CloudFront Origin Access Control resource
# Configures the access control that CloudFront uses when requesting content from the S3 bucket
resource "aws_cloudfront_origin_access_control" "cloudfront_s3_oac" {
    name                              = "OAC for S3 buckets"
    description                       = "Origin Access Control for S3 Bucket"
    origin_access_control_origin_type = "s3"
    signing_behavior                  = "always"
    signing_protocol                  = "sigv4"
}

# CloudFront distribution for the S3 bucket
# Sets up a CDN to serve the S3 bucket content globally with low latency
resource "aws_cloudfront_distribution" "website_distribution" {
    enabled = true
    is_ipv6_enabled = true
    default_root_object = "index.html"
    aliases = [var.root_domain]
    
    origin {
        domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name
        origin_id = "S3-${local.website_bucket_id}"
        origin_access_control_id = aws_cloudfront_origin_access_control.cloudfront_s3_oac.id
    }

    default_cache_behavior {
        allowed_methods = ["GET", "HEAD"]
        cached_methods = ["GET", "HEAD"]
        cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
        target_origin_id = "S3-${local.website_bucket_id}"
        viewer_protocol_policy = "redirect-to-https"
    } 

    restrictions {
        geo_restriction {
            restriction_type = "none"
        }
    }

    viewer_certificate {
        acm_certificate_arn = local.ssl_cert_arn
        ssl_support_method = "sni-only"
        minimum_protocol_version = "TLSv1.2_2021"
    }
}

# Route 53 record to route traffic to CloudFront distribution
# This record points the domain name to the CloudFront distribution using an A record alias
resource "aws_route53_record" "cloudfront_alias_record" {
    zone_id = data.aws_route53_zone.dns_zone.zone_id
    name    = var.root_domain
    type    = "A"

    alias {
        name                   = aws_cloudfront_distribution.website_distribution.domain_name
        zone_id                = aws_cloudfront_distribution.website_distribution.hosted_zone_id
        evaluate_target_health = true
    }
}