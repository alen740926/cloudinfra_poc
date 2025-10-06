provider "aws" { region = "us-east-1" }

# Pick a globally-unique bucket name before running!
variable "bucket_name" {
  type    = string
  default = "my-unique-bucket-name-change-me-123456"
}

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
