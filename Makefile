# ==============================================================================
# Equinix + Azure Arc + Fleet Manager demo (Microsoft Ignite 2026)
#
# Thin wrapper around scripts/*.ps1 - all logic lives in PowerShell so it runs
# the same via `make` or directly with `pwsh`. Only `apply`, `connect-er` and
# `destroy` create/destroy billable resources, and all three ask for typed
# confirmation unless -AutoApprove is passed to the script directly.
# Windows PowerShell only? make PWSH="powershell -NoProfile -ExecutionPolicy Bypass -File" plan
# ==============================================================================
SHELL := pwsh
.SHELLFLAGS := -NoProfile -ExecutionPolicy Bypass -Command
PWSH ?= pwsh -NoProfile -ExecutionPolicy Bypass -File

.PHONY: help check-tools bootstrap-auth test-access select-regions plan apply \
        connect-er connect-arc join-fleet deploy-workload validate \
        show-private-path arc-proxy destroy fmt lint secret-scan all

help: ## Show this help
	@echo "Pipeline (run in order):"
	@echo "  make check-tools        00 local tools + az extensions (connectedk8s, fleet, arcgateway)"
	@echo "  make bootstrap-auth     00 az / aws / Equinix API / Equinix kube context"
	@echo "  make test-access        01 read-only preflight (add -RegisterProviders to the script to register RPs)"
	@echo "  make select-regions     02 Azure + AWS region discovery, Equinix metro check"
	@echo "  make plan               03 terraform plan (azure, aws)"
	@echo "  make apply              04 BILLABLE: AKS + Fleet, EKS, ExpressRoute circuit + gateway + proxy"
	@echo "  make connect-er         05 BILLABLE: Equinix Fabric -> ExpressRoute, private peering, BGP"
	@echo "  make connect-arc        06 Arc-enable EKS + Equinix (Arc gateway + proxy over ER)"
	@echo "  make join-fleet         07 join AKS/EKS/Equinix to Fleet with labels"
	@echo "  make deploy-workload    08 Online Boutique + overrides + placement via the Fleet hub"
	@echo "  make validate           09 end-to-end validation + reports"
	@echo "Demo helpers:"
	@echo "  make show-private-path  proof panel: Fabric, BGP, Arc gateway, proxy log, Fleet"
	@echo "  make arc-proxy          kubectl to the Equinix cluster through Arc Cluster Connect"
	@echo "Teardown / hygiene:"
	@echo "  make destroy            99 tear everything down (reverse order)"
	@echo "  make fmt | lint | secret-scan"

check-tools: ## 00
	$(PWSH) scripts/00-check-tools.ps1

bootstrap-auth: ## 00
	$(PWSH) scripts/00-bootstrap-auth.ps1

test-access: ## 01
	$(PWSH) scripts/01-test-cloud-access.ps1

select-regions: ## 02
	$(PWSH) scripts/02-select-regions.ps1

plan: ## 03
	$(PWSH) scripts/03-init-plan.ps1

apply: ## 04 (billable)
	$(PWSH) scripts/04-apply.ps1

connect-er: ## 05 (billable)
	$(PWSH) scripts/05-connect-expressroute.ps1

connect-arc: ## 06
	$(PWSH) scripts/06-connect-arc.ps1

join-fleet: ## 07
	$(PWSH) scripts/07-join-fleet.ps1

deploy-workload: ## 08
	$(PWSH) scripts/08-deploy-workload.ps1

validate: ## 09
	$(PWSH) scripts/09-validate-demo.ps1

show-private-path: ## demo helper
	$(PWSH) scripts/demo-show-private-path.ps1

arc-proxy: ## demo helper
	$(PWSH) scripts/demo-arc-proxy.ps1

destroy: ## 99
	$(PWSH) scripts/99-destroy-all.ps1

fmt: ## terraform fmt
	terraform fmt -recursive terraform/

lint: ## terraform validate + manifest + script checks
	$(PWSH) scripts/lib/lint-all.ps1

secret-scan: ## scan committable files for secrets
	$(PWSH) scripts/lib/secret-scan.ps1

all: check-tools bootstrap-auth test-access select-regions plan apply connect-er connect-arc join-fleet deploy-workload validate ## full sequence
