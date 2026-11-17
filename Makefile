# ============================================================================
# OPA Delivery — políticas OPA (Envoy ext_authz) para pipeline externo o GitOps
#
# Este Makefile es el contrato que usan los pipelines consumidores
# (Jenkins / GitHub Actions / GitLab...) después de hacer checkout de este repo.
# ============================================================================

.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# OPA para validar/testear: misma versión que corre en el cluster
OPA_VERSION   ?= 0.17.3
OPA_OS        ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
# OPA 0.17.x solo publica binarios amd64 (en Apple Silicon corre con Rosetta)
OPA_ARCH      ?= amd64
OPA_LOCAL     := .bin/opa-$(OPA_VERSION)
OPA           ?= $(shell command -v opa 2>/dev/null || echo $(OPA_LOCAL))

POLICY_DIR    := policies
OPA_KUSTOMIZE := deploy/opa
OPA_NAMESPACE ?= opa
DELIVERY      := python3 tools/opa_delivery.py
DIST_DIR      := dist

# Modo de delivery: gitops (PR + Flux) | pipeline (push + kubectl)
DELIVERY_MODE ?= gitops
BASE_BRANCH   ?= main

# GitOps (Flux Operator). GITOPS_URL = URL https/ssh de ESTE repositorio.
FLUX_INSTANCE ?= deploy/flux/flux-instance.yaml
GITOPS_URL    ?= $(shell git config --get remote.origin.url 2>/dev/null)
GITOPS_REF    ?= refs/heads/$(BASE_BRANCH)

.PHONY: help opa-bin cli-test policy-validate policy-fmt policy-fmt-check policy-test \
        policy-check test policy-render policy-bundle policy-list policy-change \
        policy-publish deploy-opa delete-opa logs-opa \
        gitops-install gitops-uninstall gitops-status gitops-reconcile clean

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ----------------------------------------------------------------------------
# Validación (común a todos los modos y CI)
# ----------------------------------------------------------------------------
opa-bin: ## Download OPA $(OPA_VERSION) to .bin/ if no 'opa' binary is in PATH
	@if [ "$(OPA)" = "$(OPA_LOCAL)" ] && [ ! -x "$(OPA_LOCAL)" ]; then \
		echo ">> Downloading OPA $(OPA_VERSION) ($(OPA_OS)/$(OPA_ARCH))..."; \
		mkdir -p .bin; \
		curl -sSfL -o "$(OPA_LOCAL)" "https://github.com/open-policy-agent/opa/releases/download/v$(OPA_VERSION)/opa_$(OPA_OS)_$(OPA_ARCH)"; \
		chmod +x "$(OPA_LOCAL)"; \
	fi
	@"$(OPA)" version | head -1

cli-test: ## Run unit tests of the delivery CLI (tools/)
	@python3 -m unittest discover -s tools -p 'test_*.py'

policy-validate: ## Validate data.authz schema (policies/authz/data.json)
	@$(DELIVERY) validate

policy-fmt: opa-bin ## Format Rego files in place
	@"$(OPA)" fmt -w $(POLICY_DIR)

policy-fmt-check: opa-bin ## Fail if Rego files are not formatted
	@out="$$("$(OPA)" fmt -l $(POLICY_DIR))"; \
	if [ -n "$$out" ]; then echo "Rego sin formato (ejecuta 'make policy-fmt'):"; echo "$$out"; exit 1; fi
	@echo "OK: Rego formateado"

policy-test: opa-bin ## Run opa check + opa test on policies
	@"$(OPA)" check $(POLICY_DIR)
	@"$(OPA)" test -v $(POLICY_DIR)

policy-check: policy-validate policy-fmt-check policy-test ## Policy gate used by every CI (schema + fmt + opa test)

test: cli-test policy-check ## All offline tests (CLI + policies)

policy-render: ## Render OPA manifests (kustomize) to dist/opa-manifests.yaml
	@mkdir -p $(DIST_DIR)
	@kubectl kustomize $(OPA_KUSTOMIZE) > $(DIST_DIR)/opa-manifests.yaml
	@echo ">> $(DIST_DIR)/opa-manifests.yaml"

policy-bundle: ## Build OPA bundle dist/opa-bundle.tar.gz (Artifactory/ACR a futuro)
	@mkdir -p $(DIST_DIR)
	@tar -czf $(DIST_DIR)/opa-bundle.tar.gz --exclude='*_test.rego' --exclude='kustomization.yaml' -C $(POLICY_DIR) authz envoy
	@echo ">> $(DIST_DIR)/opa-bundle.tar.gz"; tar -tzf $(DIST_DIR)/opa-bundle.tar.gz

# ----------------------------------------------------------------------------
# Cambios sobre data.authz
# ----------------------------------------------------------------------------
policy-list: ## List callers / endpoints currently authorized
	@$(DELIVERY) list

# Uso: make policy-change ARGS='add-endpoint --caller guest --path /api/x --methods GET'
#      make policy-change ARGS='apply --spec examples/changes/example.json'
policy-change: ## Apply a change to data.authz (ARGS='<operation> ...')
	@test -n "$(ARGS)" || (echo "Uso: make policy-change ARGS='add-endpoint --caller guest --path /api/x --methods GET'"; exit 2)
	@$(DELIVERY) $(ARGS)

policy-publish: policy-check ## Publish change: DELIVERY_MODE=gitops (PR) | pipeline (push + kubectl)
	@DELIVERY_MODE=$(DELIVERY_MODE) BASE_BRANCH=$(BASE_BRANCH) scripts/publish-change.sh

# ----------------------------------------------------------------------------
# Modo pipeline externo (kubectl contra el contexto actual)
# ----------------------------------------------------------------------------
deploy-opa: ## Deploy OPA + policies with kubectl apply -k deploy/opa
	@echo ">> kubectl context: $$(kubectl config current-context)"
	@kubectl apply -k $(OPA_KUSTOMIZE)
	@kubectl -n $(OPA_NAMESPACE) rollout status deployment/opa --timeout=180s

delete-opa: ## Delete OPA resources (namespace opa)
	@kubectl delete -k $(OPA_KUSTOMIZE) --ignore-not-found

logs-opa: ## Tail OPA decision logs
	@kubectl logs -n $(OPA_NAMESPACE) -l app=opa -c opa -f

# ----------------------------------------------------------------------------
# Modo GitOps (Flux Operator)
# ----------------------------------------------------------------------------
gitops-install: ## Install Flux Operator + FluxInstance syncing this repo (GITOPS_URL, GITOPS_REF)
	@test -n "$(GITOPS_URL)" || (echo "Define GITOPS_URL=<url de este repo>"; exit 2)
	@echo ">> Installing Flux Operator..."
	@helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--namespace flux-system --create-namespace --wait
	@echo ">> Applying FluxInstance (url=$(GITOPS_URL) ref=$(GITOPS_REF))..."
	@sed -e 's|url: ".*"|url: "$(GITOPS_URL)"|' -e 's|ref: ".*"|ref: "$(GITOPS_REF)"|' $(FLUX_INSTANCE) | kubectl apply -f -
	@kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m
	@$(MAKE) --no-print-directory gitops-status

gitops-uninstall: ## Remove FluxInstance and Flux Operator (OPA resources stay in place)
	@kubectl -n flux-system delete fluxinstance flux --ignore-not-found
	@helm uninstall flux-operator -n flux-system || true

gitops-status: ## Show Flux sources and kustomizations
	@flux get sources git -A || true
	@flux get kustomizations -A || true

gitops-reconcile: ## Force Flux to pull Git and re-apply OPA now
	@flux reconcile kustomization opa -n flux-system --with-source

clean: ## Remove local build outputs
	@rm -rf $(DIST_DIR) .bin
