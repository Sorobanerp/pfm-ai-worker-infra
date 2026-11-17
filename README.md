# pfm-ai-worker-infra

Repositório 1:1 de Infraestrutura como Código (OpenTofu/Terraform Multi-Cloud + Helm + KEDA Scale-to-Zero + CI/CD DevSecOps) para o microsserviço `pfm-ai-worker-python`.

---

## Topologia de Portas: Local Host vs. Kubernetes Cloud

- **Host Local (`values-local.yaml`):** Health HTTP `18400` (`WORKER_PORT`), PostgreSQL `15433`, Kafka `19092`, LocalStack `14566`.
- **Produção K8s (`values-prod.yaml`):** Health HTTP `8080` (Service & Container), PostgreSQL `5432`, Kafka `9092`.
