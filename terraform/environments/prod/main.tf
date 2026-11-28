provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.shared_state_bucket
    key    = "pfm-shared/${var.environment}/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  kms_master_key_arn         = try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, "arn:aws:kms:${var.aws_region}:366476833548:alias/pfm-master-key")
  datadog_api_key_secret_arn = try(data.terraform_remote_state.shared.outputs.datadog_api_key_secret_arn, "arn:aws:secretsmanager:${var.aws_region}:*:secret:pfm/${var.environment}/datadog/api-key-*")
}

module "ai_worker" {
  source                     = "../../modules/ai-worker"
  environment                = var.environment
  aws_region                 = var.aws_region
  compute_engine             = var.compute_engine
  image_tag                  = var.image_tag
  desired_count              = var.desired_count
  min_capacity               = var.min_capacity
  max_capacity               = var.max_capacity
  enable_cloudwatch_logs     = var.enable_cloudwatch_logs
  kms_master_key_arn         = local.kms_master_key_arn
  datadog_api_key_secret_arn = local.datadog_api_key_secret_arn
}
