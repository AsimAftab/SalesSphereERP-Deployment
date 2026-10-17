# Minimal Azure deployment

## Topology and cost boundary

One existing Ubuntu VM runs Caddy, the frontend, backend, and Redis in Compose.
One existing Azure PostgreSQL 16 Flexible Server holds ERP data. Keep application
secrets in `/home/deploy/SalesSphereERP-Deployment/.env`, owned by `deploy`, mode
`0600`. There is no Key Vault, App Service, ACR, managed Redis, or second VM.

| Resource | Existing production value |
| --- | --- |
| Subscription | `dbc92609-fae7-45fd-8a98-b89d39828cd4` |
| Resource group | `rg-salessphere-erp-prod-eastasia` |
| VM | `vm-salessphere-erp`, `Standard_B2als_v2` |
| Static public IP | `52.184.100.204` |
| PostgreSQL | `psql-salessphere-erp-ea.postgres.database.azure.com` |
| Application database | `postgres` (contains migrated ERP data) |
| Production domains | `salessphere360.tech`, `api.salessphere360.tech` |

Terraform adds only private Standard LRS Blob state storage and non-compute OIDC
identities/access grants. State storage has a small usage-based charge.

**Budget warning:** inspected retail prices for the existing VM, PostgreSQL
compute/storage, and VM disk total approximately INR 6,600 per 730-hour month,
before IP, traffic, taxes, or credits. This is not an INR 4,000-5,000 total-spend
configuration. The subscription's spending limit was On when inspected, but its
remaining Visual Studio credit balance could not be verified through the tested
API. Confirm the balance in the Azure billing portal before launch. Credits
reduce payment, not underlying resource cost; exhausted credits can stop service.
Never disable the spending limit automatically. Resizing requires approval and
load/memory checks, not merely a smaller number in Terraform.

## Terraform state and adoption

Requirements: Terraform 1.12+, Azure CLI authentication to the correct
subscription, and access to the production and state resource groups.

The checked-in provider lockfiles pin the tested provider. Use `terraform init`
without `-upgrade` for normal operations.

The state backend is `stsserptfdbc92609`, private container `tfstate` in
`rg-salessphere-erp-tfstate-eastasia`. Shared-key authentication is disabled.
Use Entra authentication and Blob leases. Blob versions and deletion recovery
are enabled. Never commit state, saved plans, access keys, or `.env`.

The bootstrap root manages state storage, two managed identities, their
GitHub federated credentials, and scoped role assignments. Its state key is
`bootstrap.tfstate`; the production root uses `production.tfstate`.

For a new bootstrap, initialize locally first without the backend declaration
enabled, supply the variables in
[`terraform/bootstrap/main.tf`](../terraform/bootstrap/main.tf), review and apply
the plan, then enable [`backend.tf`](../terraform/bootstrap/backend.tf) and migrate
state with `terraform init -migrate-state`. Keep the initial local state protected
until remote migration is verified. Do not re-bootstrap existing resources.

For the existing production state:

```bash
az login
az account set --subscription dbc92609-fae7-45fd-8a98-b89d39828cd4
cd terraform/environments/production
cp backend.tfbackend.example backend.tfbackend
# Fill the storage account from the bootstrap output.
terraform init -backend-config=backend.tfbackend
export TF_VAR_admin_ssh_public_key="$(az vm show \
  -g rg-salessphere-erp-prod-eastasia -n vm-salessphere-erp \
  --query 'osProfile.linuxConfiguration.ssh.publicKeys[0].keyData' -o tsv)"
terraform plan -out=adoption.tfplan
terraform show adoption.tfplan
# Apply only after explicit review/approval:
terraform apply adoption.tfplan
terraform plan
```

The initial expected plan is **17 imports, 0 adds, 0 changes, 0 destroys**.
Read-only verification located the migrated schema in `postgres`; the existing
`salessphere` database is empty. Both are preserved on the same existing server;
there is no extra PostgreSQL server or compute charge.
Do not apply a plan that resets the database password, replaces the VM, removes
tags, deletes rules, or recreates the public IP. The OS disk is owned by the VM
resource, not separately managed by a conflicting Terraform resource.

Existing PostgreSQL firewall rules, including an all-IPv4 rule, are preserved
at the owner's explicit request. This is not a recommended new-environment
firewall policy. Remove broad access only through a separately approved plan
after required client/VM access is verified.

## GitHub infrastructure workflows

Repository variables:

- `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`
- `AZURE_PLAN_CLIENT_ID`, `AZURE_APPLY_CLIENT_ID`
- `AZURE_VM_SSH_PUBLIC_KEY` (public key only)
- `TF_STATE_STORAGE_ACCOUNT`

The `terraform-plan` environment permits only `main`. Its OIDC identity has
Reader access to ERP infrastructure and Blob Data Contributor access to state
(needed for lease locking). Untrusted pull requests receive offline validation
only, without Azure credentials.

The `terraform-apply` environment permits only `main` and requires an owner
review. Its separate OIDC identity has Contributor access to the ERP resource
group and Blob Data Contributor access to state. No subscription-wide write role
or client secret is used.

1. Run **Terraform validation and plan** on `main`.
2. Review the saved `terraform-plan-<run-id>` artifact and exact revision.
3. Dispatch **Terraform apply reviewed plan** with the plan run ID, full SHA, and
   explicit approval checkbox.
4. Approve the `terraform-apply` environment in GitHub.

The apply verifies trusted workflow provenance, artifact checksum/metadata,
successful plan status, and that the revision remains `main` HEAD. It applies
only the saved plan. Stale plans fail; replan and review again. Plan and apply
share a concurrency group. Application releases never run Terraform.

## Host bootstrap without a database write

From this repository on the VM:

```bash
sudo bash bootstrap-host.sh /path/to/deploy-key.pub
```

This installs Docker/Compose and bounded Docker logging, configures UFW for
22/80/443, creates the `deploy` user, installs the public key, and clones or
fast-forwards the deployment repo. It does not run containers, migrate, seed,
write secrets, or change DNS. Repeating it preserves `.env` and Docker volumes.

Use strict SSH host verification. Obtain host keys through an already trusted
SSH connection or an independent trusted console, not an unauthenticated scan.
Set `SERVER_KNOWN_HOSTS` in both application repos; include `[host]:port` when
using a nonstandard port. Never use the admin private key as a Terraform input.

## Secrets and migrated database preflight

Azure exposes the PostgreSQL hostname and username, **not its existing password**.
Provision the connection string securely; do not reset a migrated database
password or read the legacy application's files to bypass missing credentials.
Use the Azure hostname, database `postgres`, and verified TLS. Do not copy the
stale AWS RDS URL from a developer `.env`.

Before starting the backend:

- Verify the connection with certificate verification enabled.
- Inspect schema, migration history, and aggregate data counts read-only.
- Confirm recoverability and review any pending migrations.
- Preserve existing data; do not run a development seed or database reset.
- Set production JWT/refresh/CSRF secrets, origins, cookies, Cloudinary, and email.
- Use `MARKETING_SITE_URL`; the installer accepts legacy `MARKETING_URL` and
  renders the canonical setting too.
- Keep a protected backup of `.env` outside Git; replacing a VM does not
  automatically restore secrets or Redis volumes.

## App pipelines and first release

Both app workflows use the same Azure destination, key, pinned host verification,
deployment directory, and public health URLs. See [the settings table](../README.md#shared-github-deployment-secrets).

CI passes its short-lived `GITHUB_TOKEN` over SSH standard input to
[`release.sh`](../release.sh). Under the same server-wide lock used by
[`deploy.sh`](../deploy.sh), the script authenticates to GHCR, pulls the immutable
image, then delegates the rollout. It never logs the token. This prevents
concurrent repos from overwriting registry credentials during each other's pull.
GitHub tokens expire; each release authenticates again. Manual private-image
pulls require a separately provisioned read-only package credential.

Keep `DEPLOY_ENABLED=false` while preparing. Dispatch either application workflow
with `prepare_only=true` to validate/build/publish/authenticate/pull without
starting services or running migrations. Preparation requires `release.sh` to be
present on the prepared host.

Start and validate Redis plus both app containers internally first. Check
`app:3000/health/ready`, `frontend:8080/healthz`, compiled frontend URLs, and correct
host-header routing without publishing internal ports.

Only then change the A records:

```text
salessphere360.tech      -> 52.184.100.204
api.salessphere360.tech  -> 52.184.100.204
```

Preserve unrelated DNS records, check CAA/CNAME/AAAA conflicts, and retain prior
values for rollback. Orderbox nameservers were detected; account/API access must
be provided or the owner must make the changes. Automatic public ACME TLS may
require the DNS cutover; internal health checks do not.

Verify authoritative/public DNS, Caddy certificates, public health URLs, frontend
deep links, cookies/CSRF/login, and Socket.io using an authorized test account
without modifying customer books. Then set `DEPLOY_ENABLED=true` and verify a
successful normal release from each app repo.

Do not mistake a successful image build or prepare-only workflow for deployment.
Image rollback does not reverse a schema change. Existing deployment safeguards
disable automatic backend rollback when that rollout changed the schema.

## Replicating a fresh environment

Use a separate state key and explicit overrides for subscription/resource group,
location, suffix, globally unique PostgreSQL name, disk name, public SSH key,
and firewall rules; set `adopt_existing=false`. The checked-in import IDs must
never adopt production resources into a second environment.

For a fresh password-authenticated database only, copy
[`password_override.tf.example`](../terraform/environments/production/password_override.tf.example)
to the ignored `password_override.tf`, set `postgres_password_version=1`, and
provide `TF_VAR_postgres_admin_password` through a protected environment variable.
The password is ephemeral and the provider attribute is write-only, so the value
is not stored in state/plans. Keep it available for the apply as well. Never
enable this override during production adoption.

Fresh infrastructure creates `salessphere`; adopted production uses the existing
`postgres` database. Read the `application_database` Terraform output rather than
assuming they have the same name.

Bootstrap the host separately and restore secrets/data explicitly. Terraform
creates infrastructure; it does not clone ERP data, Redis jobs, credentials,
or TLS certificates. The supplied production layout is single-VM, not HA.
