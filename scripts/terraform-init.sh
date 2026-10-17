#!/usr/bin/env bash
set -euo pipefail

: "${ARM_SUBSCRIPTION_ID:?ARM_SUBSCRIPTION_ID is required}"
: "${ARM_TENANT_ID:?ARM_TENANT_ID is required}"
: "${TF_STATE_STORAGE_ACCOUNT:?TF_STATE_STORAGE_ACCOUNT is required}"

terraform init -input=false -lockfile=readonly \
  -backend-config="resource_group_name=rg-salessphere-erp-tfstate-eastasia" \
  -backend-config="storage_account_name=$TF_STATE_STORAGE_ACCOUNT" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=production.tfstate" \
  -backend-config="use_azuread_auth=true" \
  -backend-config="use_oidc=true" \
  -backend-config="subscription_id=$ARM_SUBSCRIPTION_ID" \
  -backend-config="tenant_id=$ARM_TENANT_ID"
