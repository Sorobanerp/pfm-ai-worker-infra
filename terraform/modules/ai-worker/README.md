# Module `ai-worker` (`pfm-ai-worker-infra`)

Módulo canônico OpenTofu (Padrão Terraform Docs) para provisionamento do worker IA Serverless (`pfm-ai-worker-python-${var.environment}`, Python 3.12 Arm64) com SQS DLQ criptografada via KMS, IAM Least-Privilege (Zero PostgreSQL access conforme `ADR-009`) e Scale-to-Zero Bootstrap (`desired_count = 0, min_capacity = 0, max_capacity = 0`).

## Inputs & Outputs
Consulte `variables.tf` e `outputs.tf`.
