resource "aws_s3_bucket" "state" {
  count  = var.create_state_backend ? 1 : 0
  bucket = "${var.name_prefix}-${var.environment}-tfstate-${var.state_storage_suffix}"

  tags = {
    project    = "equinix-arc-demo"
    managed_by = "terraform-bootstrap"
  }

  lifecycle {
    precondition {
      condition     = var.state_storage_suffix != ""
      error_message = "Set state_storage_suffix (globally unique) when create_state_backend = true."
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  count  = var.create_state_backend ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = var.create_state_backend ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count                   = var.create_state_backend ? 1 : 0
  bucket                  = aws_s3_bucket.state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
