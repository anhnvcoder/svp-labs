# Replication can be configured only once versioning is on in both buckets: whoever reads these outputs waits for it.
output "name" {
  description = "Name of the bucket, available once its versioning is enabled."
  value       = aws_s3_bucket.this.bucket
  depends_on  = [aws_s3_bucket_versioning.this]
}

output "arn" {
  description = "ARN of the bucket, available once its versioning is enabled."
  value       = aws_s3_bucket.this.arn
  depends_on  = [aws_s3_bucket_versioning.this]
}
