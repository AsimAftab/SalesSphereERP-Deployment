terraform {
  required_version = ">= 1.12, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  storage_use_azuread             = true
  resource_provider_registrations = "none"
}

variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "operator_object_id" {
  type        = string
  description = "Object ID of the operator bootstrapping remote state."
}

variable "storage_account_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Use a globally unique 3-24 character lowercase alphanumeric name."
  }
}

variable "erp_resource_group_name" {
  type    = string
  default = "rg-salessphere-erp-prod-eastasia"
}

variable "github_repository" {
  type    = string
  default = "AsimAftab/SalesSphereERP-Deployment"
}

resource "azurerm_resource_group" "state" {
  name     = "rg-salessphere-erp-tfstate-eastasia"
  location = "eastasia"
  tags     = { app = "salessphere-erp", purpose = "terraform-state" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account" "state" {
  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  tags                            = azurerm_resource_group.state.tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "operator_state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.operator_object_id
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
  depends_on            = [azurerm_role_assignment.operator_state]
}

resource "azurerm_user_assigned_identity" "terraform" {
  for_each            = toset(["plan", "apply"])
  name                = "id-salessphere-erp-tf-${each.key}"
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
  tags                = azurerm_resource_group.state.tags
}

resource "azurerm_federated_identity_credential" "github" {
  for_each                  = azurerm_user_assigned_identity.terraform
  name                      = "github-${each.key}"
  user_assigned_identity_id = each.value.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:${var.github_repository}:environment:terraform-${each.key}"
}

resource "azurerm_role_assignment" "terraform_state" {
  for_each             = azurerm_user_assigned_identity.terraform
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value.principal_id
}

resource "azurerm_role_assignment" "terraform_infrastructure" {
  for_each             = azurerm_user_assigned_identity.terraform
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.erp_resource_group_name}"
  role_definition_name = each.key == "plan" ? "Reader" : "Contributor"
  principal_id         = each.value.principal_id
}

output "backend" {
  value = {
    resource_group_name  = azurerm_resource_group.state.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azurerm_storage_container.state.name
    use_azuread_auth     = true
    subscription_id      = var.subscription_id
    tenant_id            = var.tenant_id
  }
}

output "github_client_ids" {
  value = { for name, identity in azurerm_user_assigned_identity.terraform : name => identity.client_id }
}
