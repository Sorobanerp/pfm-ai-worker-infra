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
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "shared_state_bucket" {
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
  description = "S3 bucket storing pfm-shared-infra remote state"
}

variable "kms_master_key_arn" {
  type        = string
  default     = ""
  description = "Optional override for KMS Master Key ARN"
}

variable "oidc_provider_arn" {
  type        = string
  default     = ""
  description = "Optional override for EKS OIDC Provider ARN"
}

variable "oidc_issuer_url" {
  type        = string
  default     = ""
  description = "Optional override for EKS OIDC Issuer URL without https://"
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.shared_state_bucket
    key    = "pfm-shared-infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  kms_master_key_arn = coalesce(var.kms_master_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, ""))
  oidc_provider_arn  = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  oidc_issuer_url    = coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
  private_subnet_ids = try(data.terraform_remote_state.shared.outputs.private_subnet_ids, [])
  vpc_id             = try(data.terraform_remote_state.shared.outputs.vpc_id, "")
}

resource "aws_secretsmanager_secret" "gemini_api_key" {
  name        = "pfm/${var.environment}/ai-worker/gemini-api-key"
  description = "Google Gemini API Key for Layer 3 Structured Outputs classification"
  kms_key_id  = local.kms_master_key_arn
}

resource "aws_db_subnet_group" "pfm_ai_rules" {
  name       = "pfm-ai-rules-subnets-${var.environment}"
  subnet_ids = local.private_subnet_ids
}

resource "aws_security_group" "pfm_ai_rules" {
  name        = "pfm-ai-rules-rds-sg-${var.environment}"
  description = "Restrict AI Rules PostgreSQL 5433 access to VPC CIDR"
  vpc_id      = local.vpc_id

  ingress {
    description = "PostgreSQL 5433 from internal VPC"
    from_port   = 5433
    to_port     = 5433
    protocol    = "tcp"
    cidr_blocks = ["10.20.0.0/16"]
  }

  egress {
    description = "Internal VPC responses only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.20.0.0/16"]
  }
}

resource "aws_db_instance" "pfm_ai_rules" {
  identifier                      = "pfm-ai-rules-${var.environment}"
  engine                          = "postgres"
  engine_version                  = "16.4"
  instance_class                  = "db.t4g.micro"
  allocated_storage               = 20
  db_name                         = "pfm_ai_rules"
  port                            = 5433
  username                        = "pfm_ai_user"
  manage_master_user_password     = true
  master_user_secret_kms_key_id   = local.kms_master_key_arn
  storage_encrypted               = true
  kms_key_id                      = local.kms_master_key_arn
  publicly_accessible             = false
  db_subnet_group_name            = aws_db_subnet_group.pfm_ai_rules.name
  vpc_security_group_ids          = [aws_security_group.pfm_ai_rules.id]
  backup_retention_period         = 7
  performance_insights_enabled    = true
  performance_insights_kms_key_id = local.kms_master_key_arn
  skip_final_snapshot             = true
}

resource "aws_iam_role" "ai_worker_role" {
  name = "pfm-ai-worker-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_url}:sub" = "system:serviceaccount:pfm-platform:pfm-ai-worker-sa"
          "${local.oidc_issuer_url}:aud" = "sts.amazonaws.com"
        }
      }
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
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.gemini_api_key.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.kms_master_key_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = [aws_db_instance.pfm_ai_rules.arn]
      }
    ]
  })
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-ai-worker-python ServiceAccount"
  value       = aws_iam_role.ai_worker_role.arn
}
