output "state_bucket_name" {
  description = "S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "S3 state bucket ARN."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.locks.name
}

output "backend_config" {
  description = "Backend values for production roots."
  value = {
    bucket         = aws_s3_bucket.state.bucket
    dynamodb_table = aws_dynamodb_table.locks.name
    encrypt        = true
    region         = var.aws_region
  }
}

output "backend_config_hcl" {
  description = "Copyable non-secret S3 backend settings. Add a key per root."
  value       = <<-EOT
bucket         = "${aws_s3_bucket.state.bucket}"
dynamodb_table = "${aws_dynamodb_table.locks.name}"
encrypt        = true
region         = "${var.aws_region}"
EOT
}
