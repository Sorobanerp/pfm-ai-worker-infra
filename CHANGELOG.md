# Changelog — `pfm-ai-worker-infra`

Todas as alterações notáveis neste repositório são documentadas neste arquivo seguindo o padrão [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e versionamento semântico [SemVer 2.0.0](https://semver.org/lang/pt-BR/).

---

## [Unreleased]

### Changed
- Conversão da infraestrutura do Worker IA (`terraform/aws/main.tf`) para **AWS Lambda Arm64** (`python3.12`, `512MB`, `timeout = 30s`, `src.adapter.in.lambda_handler.handler`) conforme **ADR-009**, com custo \$0 ocioso e remoção de permissões RDS/PostgreSQL.

### Added
- Dead Letter Queue SQS cifrada via KMS (`aws_sqs_queue.ai_worker_dlq`), Lambda Function URL autenticada por `AWS_IAM` para triggers de webhook/Kafka e IAM Least Privilege.
- Padronização de governança DevEx (`README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`) e workflow de validação de **Conventional Commits** em Pull Requests para `develop` e `main`.

---

## [0.2.0] - 2026-11-20

### Added
- Configuração FinOps `desired_count = 0` / `min_capacity = 0` orientada a eventos.

### Changed
- Alinhamento com a arquitetura **PFM Core Banking V3.0 (Production-Ready FinOps & Multi-Cloud)**.

### Security
- Aplicação estrita de políticas Zero-Trust (OIDC sem chaves estáticas, Trivy/Semgrep/Gitleaks gates e isolamento por tenant).

### Infrastructure
- Rollback automático de state S3 (`last-good`) e limpeza de workflows legados.

---

## [0.1.0] - 2026-11-15

### Added
- Estrutura inicial do repositório `pfm-ai-worker-infra`, pipelines GitHub Actions e integração ao ecossistema Gitflow `Sorobanerp`.
