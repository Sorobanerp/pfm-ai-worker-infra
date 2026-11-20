terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
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

variable "compute_engine" {
  description = "Compute engine for workloads: lambda_arm64 (ADR-009 Serverless Pilot) or eks"
  type        = string
  default     = "lambda_arm64"
}

variable "shared_state_bucket" {
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
  description = "S3 bucket storing pfm-shared-infra remote state"
}

variable "image_repository" {
  description = "Container image repository"
  type        = string
  default     = "public.ecr.aws/docker/library/busybox"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "1.36"
}

variable "eks_cluster_name" {
  type        = string
  default     = ""
  description = "Optional override for EKS cluster name"
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

variable "kafka_bootstrap_servers" {
  type        = string
  default     = ""
  description = "Upstash Kafka Serverless bootstrap servers"
}

variable "kafka_sasl_username" {
  type        = string
  default     = "upstash-placeholder"
  description = "Upstash Kafka SASL username"
}

variable "kafka_sasl_password" {
  type        = string
  default     = "placeholder-wave3"
  sensitive   = true
  description = "Upstash Kafka SASL password"
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
  eks_cluster_name       = coalesce(var.eks_cluster_name, try(data.terraform_remote_state.shared.outputs.eks_cluster_name, "pfm-eks-prod"))
  kms_master_key_arn     = coalesce(var.kms_master_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, "arn:aws:kms:us-east-2:366476833548:alias/pfm-master-key"))
  oidc_provider_arn      = try(coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, null)), "")
  oidc_issuer_url        = try(coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, null)), "")
  shared_rds_resource_id = coalesce(var.shared_rds_resource_id, try(data.terraform_remote_state.shared.outputs.rds_resource_id, "db-PFMCORELEDGER01"))
  shared_rds_endpoint    = try(data.terraform_remote_state.shared.outputs.rds_endpoint, "")

  # ECS Pilot Locals
  ecs_cluster_arn             = try(data.terraform_remote_state.shared.outputs.ecs_cluster_arn, "arn:aws:ecs:us-east-2:366476833548:cluster/pfm-pilot-prod")
  ecs_cluster_name            = try(data.terraform_remote_state.shared.outputs.ecs_cluster_name, "pfm-pilot-prod")
  ecs_tasks_security_group_id = try(data.terraform_remote_state.shared.outputs.ecs_tasks_security_group_id, "")
  cloud_map_namespace_arn     = try(data.terraform_remote_state.shared.outputs.cloud_map_namespace_arn, "")
  public_subnet_ids           = try(data.terraform_remote_state.shared.outputs.public_subnet_ids, [])
  private_subnet_ids          = try(data.terraform_remote_state.shared.outputs.private_subnet_ids, [])
  task_subnet_ids             = length(local.public_subnet_ids) > 0 ? local.public_subnet_ids : local.private_subnet_ids
  upstash_kafka_secret_arn    = try(data.terraform_remote_state.shared.outputs.upstash_kafka_secret_arn, "")
}

resource "aws_secretsmanager_secret" "gemini_api_key" {
  name        = "pfm/${var.environment}/ai-worker/gemini-api-key"
  description = "Google Gemini API Key for Layer 3 Structured Outputs classification"
  kms_key_id  = local.kms_master_key_arn
}

# =============================================================================
# Amazon ECS Fargate Spot & Service Connect Pilot (ADR-008)
# =============================================================================

# =============================================================================
# AWS Lambda Arm64 Serverless (ADR-009: $0 idle, 512MB, timeout 30s, KMS DLQ)
# =============================================================================

resource "aws_sqs_queue" "ai_worker_dlq" {
  count                     = var.compute_engine != "eks" ? 1 : 0
  name                      = "pfm-ai-worker-dlq-${var.environment}"
  kms_master_key_id         = local.kms_master_key_arn
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
    ADR         = "ADR-009"
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  count             = var.compute_engine != "eks" ? 1 : 0
  name              = "/aws/lambda/pfm-ai-worker-python-${var.environment}"
  retention_in_days = 7
  # trivy:ignore:AVD-AWS-0017 Standard CloudWatch retention for pilot FinOps
  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_iam_role" "lambda_role" {
  count       = var.compute_engine != "eks" ? 1 : 0
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
  count = var.compute_engine != "eks" ? 1 : 0
  name  = "pfm-ai-worker-lambda-policy"
  role  = aws_iam_role.lambda_role[0].id

  # trivy:ignore:AVD-AWS-0057 Scoped to secret prefix and required CloudWatch/DLQ actions
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["${aws_cloudwatch_log_group.lambda_logs[0].arn}:*"]
      },
      {
        Sid    = "ReadGeminiAndUpstashSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          aws_secretsmanager_secret.gemini_api_key.arn,
          "arn:aws:secretsmanager:${var.aws_region}:*:secret:pfm/upstash/*"
        ]
      },
      {
        Sid      = "KmsDecryptAndGenerateDataKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [local.kms_master_key_arn]
      },
      {
        Sid      = "SendToEncryptedDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.ai_worker_dlq[0].arn]
      }
    ]
  })
}

data "archive_file" "lambda_stub" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda_stub.zip"

  source {
    content  = "def handler(event, context):\n    return {'statusCode': 200, 'body': 'stub'}\n"
    filename = "lambda_stub.py"
  }
}

resource "aws_lambda_function" "ai_worker" {
  count            = var.compute_engine != "eks" ? 1 : 0
  function_name    = "pfm-ai-worker-python-${var.environment}"
  role             = aws_iam_role.lambda_role[0].arn
  handler          = "src.adapter.in.lambda_handler.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 512
  timeout          = 30
  filename         = data.archive_file.lambda_stub.output_path
  source_code_hash = data.archive_file.lambda_stub.output_base64sha256

  dead_letter_config {
    target_arn = aws_sqs_queue.ai_worker_dlq[0].arn
  }

  environment {
    variables = {
      APP_ENV              = var.environment
      TX_CATEGORIZED_TOPIC = "tx.categorized"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda_logs]

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
    ADR         = "ADR-009"
  }
}

resource "aws_lambda_function_url" "ai_worker_webhook" {
  count              = var.compute_engine != "eks" ? 1 : 0
  function_name      = aws_lambda_function.ai_worker[0].function_name
  authorization_type = "AWS_IAM"
}

# =============================================================================
# EKS / Kubernetes Support (Optional / Legacy when compute_engine = "eks")
# =============================================================================

data "aws_eks_cluster" "eks" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = var.compute_engine == "eks" ? data.aws_eks_cluster.eks[0].endpoint : "https://127.0.0.1"
  cluster_ca_certificate = var.compute_engine == "eks" ? base64decode(data.aws_eks_cluster.eks[0].certificate_authority[0].data) : ""
  token                  = var.compute_engine == "eks" ? data.aws_eks_cluster_auth.eks[0].token : ""
}

provider "helm" {
  kubernetes {
    host                   = var.compute_engine == "eks" ? data.aws_eks_cluster.eks[0].endpoint : "https://127.0.0.1"
    cluster_ca_certificate = var.compute_engine == "eks" ? base64decode(data.aws_eks_cluster.eks[0].certificate_authority[0].data) : ""
    token                  = var.compute_engine == "eks" ? data.aws_eks_cluster_auth.eks[0].token : ""
  }
}

resource "aws_iam_role" "ai_worker_role" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = "pfm-ai-worker-role-${var.environment}"
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
  count = var.compute_engine == "eks" ? 1 : 0
  name  = "pfm-ai-worker-secrets-rds-policy"
  role  = aws_iam_role.ai_worker_role[0].id
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

resource "kubernetes_service_account_v1" "ai_worker_sa" {
  count = var.compute_engine == "eks" ? 1 : 0
  metadata {
    name      = "pfm-ai-worker-sa"
    namespace = "pfm-platform"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ai_worker_role[0].arn
    }
  }
}

resource "kubernetes_secret_v1" "kafka_credentials" {
  count = var.compute_engine == "eks" ? 1 : 0
  metadata {
    name      = "pfm-kafka-credentials"
    namespace = "pfm-platform"
  }

  data = {
    sasl     = "scram_sha256"
    tls      = "enable"
    username = var.kafka_sasl_username
    password = var.kafka_sasl_password
  }

  type = "Opaque"
}

resource "helm_release" "pfm_ai_worker" {
  count            = var.compute_engine == "eks" ? 1 : 0
  name             = "pfm-ai-worker"
  chart            = "${path.module}/../../helm"
  namespace        = "pfm-platform"
  create_namespace = false
  wait             = false
  values           = [file("${path.module}/../../helm/values-prod.yaml")]

  set {
    name  = "replicaCount"
    value = "0"
  }

  set {
    name  = "imageRepository"
    value = "public.ecr.aws/docker/library/busybox"
  }

  set {
    name  = "imageTag"
    value = "1.36"
  }

  set {
    name  = "serviceAccountName"
    value = kubernetes_service_account_v1.ai_worker_sa[0].metadata[0].name
  }

  set {
    name  = "kafkaBootstrapServers"
    value = var.kafka_bootstrap_servers
  }

  set {
    name  = "chartChecksum"
    value = filesha256("${path.module}/../../helm/templates/keda-kafka-scaler.yaml")
  }

  depends_on = [
    kubernetes_service_account_v1.ai_worker_sa,
    kubernetes_secret_v1.kafka_credentials
  ]
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-ai-worker-python ServiceAccount"
  value       = try(aws_iam_role.ai_worker_role[0].arn, "")
}

output "shared_rds_endpoint" {
  description = "Shared PostgreSQL 16 RDS endpoint consumed from pfm-shared-infra"
  value       = local.shared_rds_endpoint
}

output "lambda_function_arn" {
  description = "AWS Lambda Arm64 ARN for pfm-ai-worker-python (ADR-009)"
  value       = try(aws_lambda_function.ai_worker[0].arn, "")
}

output "lambda_function_url" {
  description = "AWS IAM-authenticated Function URL for Kafka/Webhook event triggers"
  value       = try(aws_lambda_function_url.ai_worker_webhook[0].function_url, "")
}

output "dlq_arn" {
  description = "KMS-encrypted SQS Dead Letter Queue ARN"
  value       = try(aws_sqs_queue.ai_worker_dlq[0].arn, "")
}
