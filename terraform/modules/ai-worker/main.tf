resource "aws_secretsmanager_secret" "gemini_api_key" {
  name                    = "pfm/${var.environment}/ai-worker/gemini-api-key"
  description             = "Google Gemini API Key for Layer 3 Structured Outputs classification"
  kms_key_id              = var.kms_master_key_arn
  recovery_window_in_days = 0

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
    ADR         = "ADR-009"
  }
}

resource "aws_sqs_queue" "ai_worker_dlq" {
  name                      = "pfm-ai-worker-dlq-${var.environment}"
  kms_master_key_id         = var.kms_master_key_arn
  message_retention_seconds = 1209600

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
    ADR         = "ADR-009"
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = "/aws/lambda/pfm-ai-worker-python-${var.environment}"
  retention_in_days = 7
  # trivy:ignore:AVD-AWS-0017 Standard CloudWatch retention when explicitly enabled
  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_iam_role" "lambda_role" {
  name        = "pfm-ai-worker-lambda-${var.environment}"
  description = "Least Privilege Role for pfm-ai-worker-python Lambda Arm64 (Zero PostgreSQL access per ADR-009)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_least_privilege" {
  name = "pfm-ai-worker-lambda-policy-${var.environment}"
  role = aws_iam_role.lambda_role.id

  # trivy:ignore:AVD-AWS-0057 Scoped to secret prefix and required DLQ actions
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsDisabledByDefault"
        Effect = "Deny"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["*"]
      },
      {
        Sid    = "ReadGeminiAndUpstashSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          aws_secretsmanager_secret.gemini_api_key.arn,
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:pfm/*"
        ]
      },
      {
        Sid      = "KmsDecryptAndGenerateDataKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.kms_master_key_arn]
      },
      {
        Sid      = "SendToEncryptedDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.ai_worker_dlq.arn]
      }
    ]
  })
}

data "archive_file" "lambda_stub" {
  type        = "zip"
  output_path = "${path.module}/lambda_stub.zip"

  source {
    content  = "def handler(event, context):\n    return {'statusCode': 200, 'body': 'stub'}\n"
    filename = "lambda_stub.py"
  }
}

# trivy:ignore:AVD-AWS-0066 X-Ray tracing omitted in FinOps MVP to avoid extra tracing fees
resource "aws_lambda_function" "ai_worker" {
  function_name    = "pfm-ai-worker-python-${var.environment}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "src.adapter.in.lambda_handler.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 512
  timeout          = 30
  filename         = data.archive_file.lambda_stub.output_path
  source_code_hash = data.archive_file.lambda_stub.output_base64sha256

  dead_letter_config {
    target_arn = aws_sqs_queue.ai_worker_dlq.arn
  }

  environment {
    variables = {
      APP_ENV                     = var.environment
      CLOUDWATCH_LOGS_ENABLED     = "false"
      TX_CATEGORIZED_TOPIC        = "tx.categorized"
      DD_SERVICE                  = "pfm-ai-worker-python"
      DD_ENV                      = var.environment
      DD_VERSION                  = var.image_tag
      DD_LOGS_INJECTION           = "true"
      DD_TRACE_SAMPLE_RATE        = "0.10"
      DD_SITE                     = "us3.datadoghq.com"
      OTEL_EXPORTER_OTLP_ENDPOINT = "https://otel-collector.pfm.internal:4318"
      DD_CREDENTIAL_ARN           = var.datadog_api_key_secret_arn
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
    ADR         = "ADR-009"
  }
}

resource "aws_lambda_function_url" "ai_worker_webhook" {
  function_name      = aws_lambda_function.ai_worker.function_name
  authorization_type = "AWS_IAM"
}
