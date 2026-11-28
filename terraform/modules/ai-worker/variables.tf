variable "environment" {
  description = "Target deployment environment (dev or prod)"
  type        = string
}

variable "aws_region" {
  description = "Primary AWS Region (Ohio)"
  type        = string
  default     = "us-east-2"
}

variable "compute_engine" {
  description = "Compute engine for workloads: lambda_arm64 (ADR-009) or ecs_fargate_spot"
  type        = string
  default     = "lambda_arm64"
}

variable "image_tag" {
  description = "Release version tag for Datadog Unified Service Tagging"
  type        = string
  default     = "1.36"
}

variable "desired_count" {
  description = "Scale-to-Zero Bootstrap desired task count (0 during bootstrap)"
  type        = number
  default     = 0
}

variable "min_capacity" {
  description = "Scale-to-Zero Bootstrap minimum capacity (0 during bootstrap)"
  type        = number
  default     = 0
}

variable "max_capacity" {
  description = "Scale-to-Zero Bootstrap maximum capacity (0 during bootstrap)"
  type        = number
  default     = 0
}

variable "enable_cloudwatch_logs" {
  description = "Disable AWS CloudWatch Logs by default (FinOps ADR-010)"
  type        = bool
  default     = false
}

variable "kms_master_key_arn" {
  description = "Shared KMS Master Key ARN from pfm-shared-infra"
  type        = string
}

variable "datadog_api_key_secret_arn" {
  description = "Secrets Manager ARN for Datadog API Key (ADR-010)"
  type        = string
  default     = ""
}
