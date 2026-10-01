# Credentials come ONLY from the environment (never .env, tfvars or state
# inputs): EQUINIX_API_CLIENTID + EQUINIX_API_CLIENTSECRET, or EQUINIX_API_TOKEN.
# scripts/00-bootstrap-auth.ps1 verifies them with a token request without
# printing anything. See docs/AUTHENTICATION-AND-PERMISSIONS.md.
provider "equinix" {}
