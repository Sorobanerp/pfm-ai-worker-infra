terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "resource_group_name" {
  type    = string
  default = "rg-pfm-ai-worker"
}

variable "location" {
  type    = string
  default = "brazilsouth"
}

resource "azurerm_user_assigned_identity" "ai_worker_identity" {
  name                = "id-pfm-ai-worker-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_key_vault_secret" "gemini_api_key" {
  name         = "pfm-ai-worker-gemini-api-key"
  value        = "MANAGED_EXTERNALLY"
  key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${var.resource_group_name}/providers/Microsoft.KeyVault/vaults/kv-pfm-${var.environment}"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_postgresql_flexible_server_database" "pfm_ai_rules" {
  name      = "pfm_ai_rules"
  server_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${var.resource_group_name}/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-pfm-ai-rules-${var.environment}"
  collation = "en_US.utf8"
  charset   = "UTF8"
}
