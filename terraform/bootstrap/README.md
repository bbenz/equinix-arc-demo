# terraform/bootstrap

Optional and **off by default**. All roots (`azure/`, `aws/`, `equinix/`,
`environments/demo/`) use local state, which is gitignored. Nothing in this folder is
needed to run the demo.

Use it if you later want shared or remote state. For example, you might want a teammate to run the
Ignite rehearsal from another machine.

| Folder | Creates (only when `create_state_backend = true`) | Holds state for |
|---|---|---|
| `azure/` | Resource group + Storage Account (versioned, TLS 1.2) + `tfstate` container | `terraform/azure` (key `azure.tfstate`) **and** `terraform/equinix` (key `equinix.tfstate`). Equinix has no state backend of its own. |
| `aws/` | S3 bucket (versioned, encrypted, public access blocked) | `terraform/aws` (key `aws.tfstate`, native S3 locking) |

Each sub-root declares only its own provider. Bootstrapping Azure state never touches AWS
credentials, and the reverse is also true. This is the same lesson the fleet-manager-arc-demo
applied: Terraform initializes every provider block a root declares, even when a resource
uses `count = 0`.

## Switching a root to remote state

1. `cd terraform/bootstrap/<cloud>`. Create a gitignored `terraform.tfvars` that contains
   `create_state_backend = true` and a globally unique `state_storage_suffix`.
2. Run `terraform init`, then `terraform apply`.
3. Paste the `state_backend_config` output into the target root's `versions.tf`.
4. Run `terraform init -migrate-state` in the target root.
5. If you migrate `terraform/azure`, `terraform/aws`, or `terraform/equinix`, point
   `terraform/environments/demo` at the remote state too. Otherwise keep a local copy for it.

Cost: with the default (`false`), these roots create nothing. When enabled, they create a single
storage account or bucket, which costs fractions of a cent per month.

The pipeline scripts read state through Terraform (`terraform state list`, `terraform output`), never
from a local file, so they work unchanged after a migration. On a fresh clone they run `terraform init`
on demand for any root that declares a backend.
