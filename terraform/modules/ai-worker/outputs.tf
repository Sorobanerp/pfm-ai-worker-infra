output "lambda_function_arn" {
  description = "AWS Lambda Arm64 ARN for pfm-ai-worker-python (ADR-009)"
  value       = aws_lambda_function.ai_worker.arn
}

output "lambda_function_name" {
  description = "AWS Lambda Arm64 Function Name"
  value       = aws_lambda_function.ai_worker.function_name
}

output "lambda_function_url" {
  description = "AWS IAM-authenticated Function URL for Kafka/Webhook event triggers"
  value       = aws_lambda_function_url.ai_worker_webhook.function_url
}

output "dlq_arn" {
  description = "KMS-encrypted SQS Dead Letter Queue ARN"
  value       = aws_sqs_queue.ai_worker_dlq.arn
}
