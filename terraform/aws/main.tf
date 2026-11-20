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
  description = "Compute engine for workloads: ecs_fargate_spot (ADR-008 Pilot) or eks"
  type        = string
  default     = "ecs_fargate_spot"
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
  oidc_provider_arn      = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  oidc_issuer_url        = coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
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

resource "aws_iam_role" "ecs_execution_role" {
  count       = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name        = "pfm-ai-worker-ecs-exec-${var.environment}"
  description = "ECS Task Execution Role for pfm-ai-worker-python"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  count      = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  role       = aws_iam_role.ecs_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  count       = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name        = "pfm-ai-worker-ecs-task-${var.environment}"
  description = "Least Privilege Task Role for pfm-ai-worker-python (RDS IAM, Gemini Secret, Upstash)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_least_privilege" {
  count = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name  = "pfm-ai-worker-ecs-task-policy"
  role  = aws_iam_role.ecs_task_role[0].id

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
      },
      {
        Sid    = "UpstashKafkaSecretsAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  count             = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name              = "/ecs/pfm-ai-worker-python-${var.environment}"
  retention_in_days = 7

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_ecs_task_definition" "service" {
  count                    = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  family                   = "pfm-ai-worker-python-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role[0].arn
  task_role_arn            = aws_iam_role.ecs_task_role[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "pfm-ai-worker-python"
      image     = "${var.image_repository}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          name          = "health"
          containerPort = 18090
          hostPort      = 18090
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ai-worker"
        }
      }
      environment = [
        { name = "APP_ENV", value = "prod" },
        { name = "HEALTH_PORT", value = "18090" }
      ]
    }
  ])

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

# FinOps: AI Worker starts at desired_count = 0 and scales up on incoming events/demand
resource "aws_ecs_service" "service" {
  count           = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name            = "pfm-ai-worker-python"
  cluster         = local.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.service[0].arn
  desired_count   = 0

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 0
  }

  network_configuration {
    subnets          = local.task_subnet_ids
    security_groups  = local.ecs_tasks_security_group_id != "" ? [local.ecs_tasks_security_group_id] : []
    assign_public_ip = true
  }

  dynamic "service_connect_configuration" {
    for_each = local.cloud_map_namespace_arn != "" ? [1] : []
    content {
      enabled   = true
      namespace = local.cloud_map_namespace_arn
      service {
        port_name      = "health"
        discovery_name = "pfm-ai-worker-python"
        client_alias {
          port     = 18090
          dns_name = "pfm-ai-worker-python.pfm.internal"
        }
      }
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_appautoscaling_target" "ecs_target" {
  count              = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  max_capacity       = 3
  min_capacity       = 0
  resource_id        = "service/${local.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu_policy" {
  count              = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name               = "pfm-ai-worker-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
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

output "ecs_service_name" {
  description = "ECS Service Name"
  value       = try(aws_ecs_service.service[0].name, "")
}

output "ecs_task_definition_arn" {
  description = "ECS Task Definition ARN"
  value       = try(aws_ecs_task_definition.service[0].arn, "")
}
