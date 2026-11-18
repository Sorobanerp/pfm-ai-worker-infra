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

variable "shared_rds_resource_id" {
  type        = string
  default     = ""
  description = "Optional override for shared PostgreSQL 16 RDS resource ID from pfm-shared-infra"
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
  kms_master_key_arn     = coalesce(var.kms_master_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, ""))
  oidc_provider_arn      = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  oidc_issuer_url        = coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
  shared_rds_resource_id = coalesce(var.shared_rds_resource_id, try(data.terraform_remote_state.shared.outputs.rds_resource_id, "db-PFMCORELEDGER01"))
  shared_rds_endpoint    = try(data.terraform_remote_state.shared.outputs.rds_endpoint, "")
}

# FinOps MVP: No duplicate aws_db_instance here!
# pfm_ai_rules logical database/schema lives on the single shared PostgreSQL 16 RDS
# provisioned by pfm-shared-infra (saves ~US$ 15/mo + eliminates duplicate backup overhead).

resource "aws_secretsmanager_secret" "gemini_api_key" {
  name        = "pfm/${var.environment}/ai-worker/gemini-api-key"
  description = "Google Gemini API Key for Layer 3 Structured Outputs classification"
  kms_key_id  = local.kms_master_key_arn
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
        Sid      = "ReadGeminiApiKeySecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.gemini_api_key.arn]
      },
      {
        Sid      = "DecryptSharedKmsMasterKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.kms_master_key_arn]
      },
      {
        Sid      = "ConnectSharedPostgresAiRulesUser"
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = ["arn:aws:rds-db:${var.aws_region}:*:dbuser:${local.shared_rds_resource_id}/pfm_ai_user"]
      }
    ]
  })
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-ai-worker-python ServiceAccount"
  value       = aws_iam_role.ai_worker_role.arn
}

output "shared_rds_endpoint" {
  description = "Shared PostgreSQL 16 RDS endpoint consumed from pfm-shared-infra"
  value       = local.shared_rds_endpoint
}
