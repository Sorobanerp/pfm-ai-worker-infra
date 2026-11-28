output "lambda_function_arn" {
  description = "AWS Lambda Arm64 ARN for pfm-ai-worker-python"
  value       = module.ai_worker.lambda_function_arn
}

output "lambda_function_url" {
  description = "AWS IAM-authenticated Function URL"
  value       = module.ai_worker.lambda_function_url
}

output "dlq_arn" {
  description = "KMS-encrypted SQS Dead Letter Queue ARN"
  value       = module.ai_worker.dlq_arn
}
