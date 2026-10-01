# Thin, resource-free composition root: reads the already-applied outputs of
# terraform/azure, terraform/aws and terraform/equinix (local state) and
# re-exposes them as one summary for scripts and the runsheet. Never calls a
# cloud API and needs no credentials.
#
# terraform_remote_state hard-errors when its state file doesn't exist, which
# try() cannot catch - so every data source is count-gated on fileexists()
# and outputs.tf wraps attribute access in try() (pattern proven in
# fleet-manager-arc-demo).

data "terraform_remote_state" "azure" {
  count   = fileexists(var.azure_state_path) ? 1 : 0
  backend = "local"
  config = {
    path = var.azure_state_path
  }
}

data "terraform_remote_state" "aws" {
  count   = fileexists(var.aws_state_path) ? 1 : 0
  backend = "local"
  config = {
    path = var.aws_state_path
  }
}

data "terraform_remote_state" "equinix" {
  count   = fileexists(var.equinix_state_path) ? 1 : 0
  backend = "local"
  config = {
    path = var.equinix_state_path
  }
}
