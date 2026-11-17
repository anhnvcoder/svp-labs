# Cross-Region Replication of the media bucket into the DR Region, with a role holding only the permissions the S3
# guide lists for replication; s3:ReplicateObject already carries tags and ACLs. Replication Time Control stays off: the
# drill measures replication time itself by polling the destination. Design notes: multi-region-dr/README.md.

resource "aws_iam_role" "this" {
  name        = var.name
  description = "S3 Cross-Region Replication of ${var.source_bucket_name} in the multi-region-dr lab"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  name = "replicate"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadReplicationConfiguration"
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = local.source_arn
      },
      {
        Sid      = "ReadSourceVersions"
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = "${local.source_arn}/*"
      },
      {
        Sid      = "WriteReplicas"
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete"]
        Resource = "${var.destination_bucket_arn}/*"
      },
    ]
  })
}

data "aws_partition" "current" {}

locals {
  source_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.source_bucket_name}"
}

# Delete markers are replicated so the replica mirrors what the application sees; both buckets keep every version, so
# a deleted object stays recoverable on either side.
resource "aws_s3_bucket_replication_configuration" "this" {
  bucket = var.source_bucket_name
  role   = aws_iam_role.this.arn

  rule {
    id     = "media-to-dr"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket = var.destination_bucket_arn
    }
  }

  depends_on = [aws_iam_role_policy.this]
}
