output "bucket_arn" {
  description = "ARN of the flow logs bucket (passed to the network stack)"
  value       = aws_s3_bucket.flowlogs.arn
}

output "bucket_name" {
  description = "Name of the flow logs bucket"
  value       = aws_s3_bucket.flowlogs.id
}
