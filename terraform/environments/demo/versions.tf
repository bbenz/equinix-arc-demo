terraform {
  required_version = ">= 1.9.0"

  # No provider requirements: this root only reads local state files of the
  # other roots via the built-in terraform_remote_state data source.
}
