\
# onedata-gitops-landscapes -- a target for every recurring action.
# Run `make help` for the full list. Everything here assumes it runs
# inside `devbox shell` (or is prefixed with `devbox run --`) so every
# tool (kubectl/kustomize/helm/argocd/gh/jq/yq) is the pinned devbox.json
# version, not whatever happens to be on PATH.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

ARGOCD_NAMESPACE ?= onedata-gitops-argocd
ARGOCD_VERSION   ?= v3.4.4
KUBECONFIG_PATH  ?= $(KUBECONFIG)

HARBOR_NAMESPACE     ?= onedata-gitops-harbor
HARBOR_INTERNAL_HOST ?= harbor.onedata-gitops-harbor.svc.cluster.local
# The 22 k8s-one nodes' external IPs all reach the same NodePort --
# override with an actual node IP (see platform/harbor/README.md's
# "Exposure and TLS" section) for harbor-login/harbor-push, which run
# from OUTSIDE the cluster (large-dev's own docker daemon).
HARBOR_HOST              ?= REPLACE-WITH-NODE-IP:30002
HARBOR_PULL_SECRET_NAME  ?= harbor-dev-pull

NAME    ?=
VERSION ?=
NS      ?=
IMAGE   ?=

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help.
	@echo "onedata-gitops-landscapes -- targets:"
	@echo
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "MANDATORY first-time deploy sequence (see README.md -- load-bearing, not optional):"
	@echo "  1. make scope-cluster-manager                       # existing k8s-one v0.5.0 manager: stop watching new namespaces"
	@echo "  2. make apply-crds                                  # superset/latest CRDs, once per cluster"
	@echo "  3. make argocd-install                               # Argo CD itself, once per cluster"
	@echo "  4. make deploy-landscape NAME=<name> VERSION=<ver>   # any landscape, any number of times"
	@echo
	@echo "Optional platform app (independent of the sequence above, needs argocd-install only):"
	@echo "  make harbor-deploy && make harbor-configure          # Harbor: proxy-cache + dev push target (it.178/179/183)"
	@echo
	@echo "Nothing in this Makefile targets a live cluster by default -- 'make validate' only renders/schema-checks."

## --- CRDs (the one shared, cluster-scoped resource) -----------------------

.PHONY: apply-crds
apply-crds: ## Apply the superset/latest onedata.org + testing.onedata.org CRDs (cluster-scoped, once per cluster; see crds/README.md).
	kubectl apply -k crds/

.PHONY: diff-crds
diff-crds: ## Show what `apply-crds` would change, without applying it.
	kubectl diff -k crds/ || true

## --- Argo CD (dedicated namespace; the one bootstrap exception) -----------

.PHONY: argocd-install
argocd-install: ## Install Argo CD into the dedicated onedata-gitops-argocd namespace (cluster-wide RBAC, NOT publicly exposed).
	kubectl apply -k argocd/
	@echo "Waiting for the argocd-server Deployment to become available..."
	kubectl -n $(ARGOCD_NAMESPACE) rollout status deploy/argocd-server --timeout=300s
	@echo "Installed. Run 'make argocd-login' then 'make argocd-ui'."

.PHONY: argocd-uninstall
argocd-uninstall: ## Tear down the Argo CD install (does NOT touch landscapes it manages -- delete those first).
	kubectl delete -k argocd/ --ignore-not-found

.PHONY: argocd-login
argocd-login: ## Fetch the generated initial admin password and log the argocd CLI in (via the port-forward from argocd-ui).
	@echo "Initial admin password:"
	@kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
	@echo "Run 'make argocd-ui' in another shell, then:"
	@echo "  argocd login localhost:8080 --username admin --insecure"

.PHONY: argocd-ui
argocd-ui: ## Port-forward the Argo CD UI to https://localhost:8080 (localhost only -- never expose this cluster-wide-RBAC instance publicly).
	@echo "Argo CD UI -> https://localhost:8080  (Ctrl-C to stop)"
	kubectl -n $(ARGOCD_NAMESPACE) port-forward svc/argocd-server 8080:443

## --- Landscapes -------------------------------------------------------------

.PHONY: list-landscapes
list-landscapes: ## List every landscape and version available in this repo.
	@for d in landscapes/*/; do \
		name=$$(basename "$$d"); \
		for v in "$$d"*/; do \
			[ -d "$$v" ] || continue; \
			ver=$$(basename "$$v"); \
			app="applications/landscapes/$${name}-$${ver}.yaml"; \
			if [ -f "$$app" ]; then st="application defined"; else st="NO application manifest"; fi; \
			printf "  %-24s %-10s (%s)\n" "$$name" "$$ver" "$$st"; \
		done; \
	done

.PHONY: deploy-landscape
deploy-landscape: ## Apply a landscape's root Application (NAME=... VERSION=...). Requires steps 1-3 of the mandatory sequence already done.
	@if [ -z "$(NAME)" ] || [ -z "$(VERSION)" ]; then echo "usage: make deploy-landscape NAME=<name> VERSION=<version>" >&2; exit 1; fi
	@app="applications/landscapes/$(NAME)-$(VERSION).yaml"; \
	if [ ! -f "$$app" ]; then echo "no such application manifest: $$app" >&2; exit 1; fi; \
	echo "Applying $$app ..."; \
	kubectl apply -f "$$app"

.PHONY: delete-landscape
delete-landscape: ## Delete a landscape's root Application (NAME=... VERSION=...). syncPolicy has no auto-prune in v1 -- resources may need a manual follow-up delete.
	@if [ -z "$(NAME)" ] || [ -z "$(VERSION)" ]; then echo "usage: make delete-landscape NAME=<name> VERSION=<version>" >&2; exit 1; fi
	@app="applications/landscapes/$(NAME)-$(VERSION).yaml"; \
	if [ ! -f "$$app" ]; then echo "no such application manifest: $$app" >&2; exit 1; fi; \
	echo "Deleting $$app ..."; \
	kubectl delete -f "$$app" --ignore-not-found

## --- Harbor (cluster-singleton platform app; it.178/179/183) ---------------
# Independent of the mandatory landscape sequence -- only needs Argo CD
# to already exist. See platform/harbor/README.md for the full design
# and the top-level README's "Harbor: proxy-cache + dev push target"
# section for the landscape-side consumption patterns.

.PHONY: harbor-deploy
harbor-deploy: ## Apply the Harbor platform Application (GATED -- requires make argocd-install first; independent of any landscape deploy).
	kubectl apply -f applications/platform/harbor.yaml

.PHONY: harbor-configure
harbor-configure: ## (Re-)run Harbor's config-as-code Job: dockerhub-proxy + dev projects + push robot (config/configure-harbor.sh). Deletes the existing Job first -- Job.spec is immutable, so this is how you pick up a script edit too.
	kubectl -n $(HARBOR_NAMESPACE) delete job harbor-configure-projects --ignore-not-found
	kustomize build platform/harbor | kubectl apply -f -
	@echo "Waiting for the config Job to complete..."
	kubectl -n $(HARBOR_NAMESPACE) wait --for=condition=complete job/harbor-configure-projects --timeout=180s

.PHONY: harbor-ui
harbor-ui: ## Port-forward the Harbor UI to http://localhost:8081 (localhost only; TLS disabled in v1 -- see platform/harbor/README.md's "Exposure and TLS"). Login: admin / harbor-admin-secret's HARBOR_ADMIN_PASSWORD.
	@echo "Harbor UI -> http://localhost:8081  (Ctrl-C to stop)"
	kubectl -n $(HARBOR_NAMESPACE) port-forward svc/harbor 8081:80

.PHONY: harbor-configure-insecure-registry
harbor-configure-insecure-registry: ## One-time per large-dev docker daemon: mark Harbor's NodePort (HARBOR_HOST=<node-ip>:30002) as an insecure registry + restart docker. Requires sudo -- see scripts/configure-docker-insecure-registry.sh for exactly what it does and its scope limits.
	@if [ "$(HARBOR_HOST)" = "REPLACE-WITH-NODE-IP:30002" ]; then echo "usage: make harbor-configure-insecure-registry HARBOR_HOST=<a-k8s-one-node-ip>:30002" >&2; exit 1; fi
	HARBOR_HOST=$(HARBOR_HOST) ./scripts/configure-docker-insecure-registry.sh

.PHONY: harbor-login
harbor-login: ## docker login to Harbor's `dev` project from large-dev, using the harbor-dev-robot account. Requires HARBOR_HOST=<node-ip>:30002 and (once) make harbor-configure-insecure-registry.
	@if [ "$(HARBOR_HOST)" = "REPLACE-WITH-NODE-IP:30002" ]; then echo "usage: make harbor-login HARBOR_HOST=<a-k8s-one-node-ip>:30002" >&2; exit 1; fi
	@user="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.username}' | base64 -d)"; \
	pass="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.password}' | base64 -d)"; \
	echo "$$pass" | docker login "$(HARBOR_HOST)" -u "$$user" --password-stdin

.PHONY: harbor-push
harbor-push: ## Tag + push IMAGE=<local-image:tag> into Harbor's `dev` project. Requires HARBOR_HOST=<node-ip>:30002 and make harbor-login first.
	@if [ -z "$(IMAGE)" ] || [ "$(HARBOR_HOST)" = "REPLACE-WITH-NODE-IP:30002" ]; then echo "usage: make harbor-push IMAGE=<local-image:tag> HARBOR_HOST=<a-k8s-one-node-ip>:30002" >&2; exit 1; fi
	@repo="$$(echo "$(IMAGE)" | sed 's/^.*\///')"; \
	target="$(HARBOR_HOST)/dev/$${repo}"; \
	echo "docker tag $(IMAGE) $${target}"; \
	docker tag "$(IMAGE)" "$${target}"; \
	echo "docker push $${target}"; \
	docker push "$${target}"

.PHONY: harbor-pull-secret
harbor-pull-secret: ## Create/update the harbor-dev-pull imagePullSecret (from harbor-dev-robot) in namespace NS, for a landscape pulling from Harbor's private `dev` project. Defaults to the in-cluster Service DNS name (HARBOR_INTERNAL_HOST) -- see the top-level README's "pull-secret pattern".
	@if [ -z "$(NS)" ]; then echo "usage: make harbor-pull-secret NS=<landscape-namespace> [HARBOR_INTERNAL_HOST=...]" >&2; exit 1; fi
	@user="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.username}' | base64 -d)"; \
	pass="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.password}' | base64 -d)"; \
	kubectl -n "$(NS)" create secret docker-registry $(HARBOR_PULL_SECRET_NAME) \
		--docker-server="$(HARBOR_INTERNAL_HOST)" \
		--docker-username="$$user" \
		--docker-password="$$pass" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "secret/$(HARBOR_PULL_SECRET_NAME) ready in namespace $(NS). Reference it via imagePullSecrets on the consuming ServiceAccount/Pod."

## --- Cluster-manager scoping (documented, NOT run by this repo automatically) ---

.PHONY: scope-cluster-manager
scope-cluster-manager: ## Restart the EXISTING k8s-one cluster-wide v0.5.0 manager scoped to landscape-max+demo-a. See scripts/scope-cluster-manager.sh. MANDATORY step 1 before any new landscape deploy.
	./scripts/scope-cluster-manager.sh

## --- Validation (no cluster contact) ---------------------------------------
# NOTE: uses `kubectl create --dry-run=client`, not `apply --dry-run=client`.
# `apply`'s dry-run computes a local strategic-merge-patch, which chokes on
# some of these CRDs ("applying patch locally: expected a struct, but
# received a nil" -- a known kubectl client-side-merge limitation for large
# generated CRD schemas with embedded corev1 types, e.g. Oneprovider's
# spec.managed.storageVolume *corev1.VolumeSource -- reproduced even with NO
# cluster context at all during this scaffold's validation, confirming it is
# a kubectl tooling quirk, not a manifest defect). `create --dry-run=client`
# is a pure decode+structural-validate with no merge computation, and is
# actually the more appropriate check for "does this render as a well-formed
# resource" anyway.

.PHONY: validate
validate: validate-argocd validate-crds validate-platform validate-landscapes validate-applications ## Render + schema-check every manifest in this repo. Touches NO live cluster.
	@echo "All manifests rendered and schema-validated (client-side only)."

.PHONY: validate-argocd
validate-argocd: ## kustomize build + dry-run the argocd/ install.
	kustomize build argocd/ | kubectl create --dry-run=client -f - -o name

.PHONY: validate-crds
validate-crds: ## kustomize build + dry-run the crds/ superset.
	kustomize build crds/ | kubectl create --dry-run=client -f - -o name

.PHONY: validate-platform
validate-platform: ## kustomize build + dry-run every platform/<app>/ (currently: platform/harbor/).
	@for d in platform/*/; do \
		echo "--- $$d ---"; \
		kustomize build "$$d" | kubectl create --dry-run=client -f - -o name; \
	done

.PHONY: validate-landscapes
validate-landscapes: ## kustomize build + dry-run every landscapes/<name>/<version>/.
	@for d in landscapes/*/*/; do \
		echo "--- $$d ---"; \
		kustomize build "$$d" | kubectl create --dry-run=client -f - -o name; \
	done

.PHONY: validate-applications
validate-applications: ## Structural-check every Argo Application manifest under applications/ (yq-based; see the comment below for why this is not full OpenAPI validation).
	# NOTE: NOT full OpenAPI schema validation. `kubectl create --dry-run=client`
	# (client-side though it is) still needs a RESTMapping for the Kind, which
	# for a CRD Argo itself owns (argoproj.io/Application) requires the CRD to
	# be registered on SOME reachable cluster -- and Argo CD is not installed
	# anywhere in scope for this repo's validation (installing it just to
	# validate against it would mean touching cluster state as a side effect
	# of "validation," which defeats the point). So this target instead does a
	# genuinely offline structural check with yq: valid YAML, and every
	# required top-level field (apiVersion, kind, metadata.name,
	# metadata.namespace, spec.project, spec.source, spec.destination) is
	# present. It will NOT catch a misspelled nested field. A real schema
	# check is possible once Argo CD's Application CRD is registered somewhere
	# (e.g. `kubectl create --dry-run=client -f <app>.yaml` against a cluster
	# that already ran `make argocd-install` or `make apply-crds`-equivalent
	# for argocd/vendor/install-v3.4.4.yaml's CRDs).
	@for f in applications/platform/*.yaml applications/landscapes/*.yaml; do \
		[ -f "$$f" ] || continue; \
		echo "--- $$f ---"; \
		yq eval '.' "$$f" > /dev/null; \
		for field in apiVersion kind metadata.name metadata.namespace spec.project spec.source spec.destination; do \
			val="$$(yq eval ".$$field" "$$f")"; \
			if [ -z "$$val" ] || [ "$$val" = "null" ]; then \
				echo "MISSING required field: $$field" >&2; exit 1; \
			fi; \
		done; \
		echo "OK (structural check only, see comment above)"; \
	done

.PHONY: devbox-shell
devbox-shell: ## Enter the pinned devbox shell (equivalent to running `devbox shell` directly).
	devbox shell
