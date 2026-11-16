terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  type    = string
  default = "pfm-platform-prod"
}

variable "environment" {
  type    = string
  default = "prod"
}

resource "google_service_account" "ai_worker_sa" {
  project      = var.project_id
  account_id   = "pfm-ai-worker-${var.environment}"
  display_name = "PFM AI Worker Service Account"
}

resource "google_secret_manager_secret" "gemini_api_key" {
  project   = var.project_id
  secret_id = "pfm-ai-worker-gemini-api-key-${var.environment}"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "ai_worker_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.gemini_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ai_worker_sa.email}"
}

resource "google_sql_database" "pfm_ai_rules" {
  project  = var.project_id
  name     = "pfm_ai_rules"
  instance = "pfm-ai-rules-pg16-${var.environment}"
}
