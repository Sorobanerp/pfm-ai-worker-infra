terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "environment" {
  type    = string
  default = "local"
}

resource "aws_secretsmanager_secret" "gemini_api_key" {
  name        = "pfm/${var.environment}/ai-worker/gemini-api-key"
  description = "Google Gemini API Key for Layer 3 Structured Outputs classification"
}

resource "aws_db_instance" "pfm_ai_rules" {
  identifier              = "pfm-ai-rules-${var.environment}"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = "pfm_ai_rules"
  port                    = 5433
  username                = "pfm_ai_user"
  manage_master_user_password = true
  storage_encrypted       = true
  skip_final_snapshot     = true
}

resource "aws_iam_role" "ai_worker_role" {
  name = "pfm-ai-worker-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ai_worker_least_privilege" {
  name = "pfm-ai-worker-secrets-rds-policy"
  role = aws_iam_role.ai_worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
        Resource = [aws_secretsmanager_secret.gemini_api_key.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = [aws_db_instance.pfm_ai_rules.arn]
      }
    ]
  })
}
