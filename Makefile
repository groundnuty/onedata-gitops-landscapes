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
# In-cluster HTTP API access ONLY (the config Job path) -- NOT a docker
# registry endpoint anymore: the Let's Encrypt cert (it.185 TLS-v2)
# covers the public dedyn.io name, not *.svc.cluster.local, so every
# docker/containerd client uses HARBOR_HOST below instead.
HARBOR_INTERNAL_HOST ?= harbor.onedata-gitops-harbor.svc.cluster.local

# --- The Harbor public name (it.185 TLS-v2; deSEC dedyn.io) ---------------
# `make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io` rewrites the
# CHANGEME placeholder REPO-WIDE (this default included) once the
# maintainer's deSEC account + domain exist. Resolves via the deSEC A
# record (`make dns-record`) to ONE node's InternalIP; the NodePort is
# reachable on all 22 nodes.
HARBOR_DOMAIN ?= harbor.k8s-one-onedata.dedyn.io
# The deSEC zone = the registered domain (dedyn.io is on the Public
# Suffix List, so <name>.dedyn.io is its own LE rate-limit bucket).
DEDYN_DOMAIN  ?= $(patsubst harbor.%,%,$(HARBOR_DOMAIN))
# The node InternalIP the A record points at (pick ANY Ready node --
# `kubectl get nodes -o wide`; e.g. k8s-one-server-0 was 10.87.23.54 at
# build time. One IP = one SPOF for the NAME only; re-run dns-record
# against another node if it dies).
HARBOR_NODE_IP ?= CHANGEME
# The docker-facing registry endpoint: HTTPS on the fixed 30003
# NodePort, genuine Let's Encrypt trust chain -- no insecure-registry
# config anywhere (the v1 HTTP workarounds are deleted; see git history
# if you must resurrect plaintext).
HARBOR_HOST              ?= $(HARBOR_DOMAIN):30003
HARBOR_PULL_SECRET_NAME  ?= harbor-dev-pull

# Where cert-manager (pre-existing on k8s-one, NOT managed by this
# repo) runs; the desec-token Secret and the webhook solver live here.
CERT_MANAGER_NAMESPACE ?= cert-manager
# `make desec-token` accepts the token as TOKEN=... or via the
# DESEC_TOKEN env var (keeps it off the make command line / shell
# history). NEVER commit it -- see
# platform/cert-manager-desec/README.md's "Token handling".
TOKEN ?= $(DESEC_TOKEN)

NAME    ?=
VERSION ?=
NS      ?=
IMAGE   ?=
DOMAIN  ?=

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
	@echo "Optional platform apps (independent of the sequence above, need argocd-install only)."
	@echo "Harbor + real Let's Encrypt TLS (it.178/179/183 + it.185/deSEC) -- THIS order is load-bearing:"
	@echo "  a. make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io   # once; rewrites the CHANGEME placeholder repo-wide, then commit"
	@echo "  b. make desec-token TOKEN=<real-desec-token>               # the ONE real credential -> cluster Secret, NEVER git"
	@echo "  c. make dns-record HARBOR_NODE_IP=<node-InternalIP>        # idempotent deSEC A record for the Harbor name"
	@echo "  d. make certmanager-desec-deploy                            # webhook solver + letsencrypt ClusterIssuers"
	@echo "  e. make harbor-deploy && make harbor-configure              # Harbor itself (TLS via the harbor-tls Certificate)"
	@echo
	@echo "onedata-dev-ca (design it.194-196/200/203) -- shared dev-CA ClusterIssuer, independent of the above:"
	@echo "  make dev-ca-deploy   # only needs argocd-install; a landscape opts in via spec.tls.issuerRef+trustIssuerCA"
	@echo
	@echo "Nothing in this Makefile targets a live cluster by default -- 'make validate' only renders/schema-checks."

## --- CRDs (the one shared, cluster-scoped resource) -----------------------

.PHONY: apply-crds
apply-crds: ## Apply the superset/latest onedata.org + testing.onedata.org CRDs (cluster-scoped, once per cluster; see crds/README.md).
	# Checked against the same it.198-defect-#1 annotation-size class as
	# argocd-install (see that target's comment): plain client-side
	# `kubectl apply` computes a last-applied-configuration annotation
	# whose JSON form must stay under the Kubernetes 256KiB
	# (262144-byte) total-annotation-size limit. Measured 2026-07-18
	# (`yq -o=json` on each crds/*.yaml, largest first): oneproviders
	# ~171.6KB, onezones ~163.3KB -- both comfortably under the ceiling
	# (~90KB/~99KB headroom), unlike argocd/vendor/install-v3.4.4.yaml's
	# ApplicationSet CRD (~1.4MB) or Applications CRD (~368KB). Plain
	# `apply -k` stays correct here; revisit this measurement if any
	# onedata.org CRD's schema grows substantially (e.g. another large
	# additive field block).
	kubectl apply -k crds/

.PHONY: diff-crds
diff-crds: ## Show what `apply-crds` would change, without applying it.
	kubectl diff -k crds/ || true

## --- Argo CD (dedicated namespace; the one bootstrap exception) -----------

.PHONY: argocd-install
argocd-install: ## Install Argo CD into the dedicated onedata-gitops-argocd namespace (cluster-wide RBAC, NOT publicly exposed).
	# --server-side --force-conflicts, NOT plain `apply -k` (it.198 deploy
	# defect #1, closed here): argocd/vendor/install-v3.4.4.yaml's
	# ApplicationSet CRD alone is ~1.4MB and the Applications CRD ~368KB
	# once client-side `kubectl apply` tries to compute a
	# last-applied-configuration annotation for either -- both blow past
	# the Kubernetes 256KiB total-annotation-size limit (a known
	# upstream Argo CD issue; verified 2026-07-18: `kubectl apply -k
	# argocd/` fails outright on this on ANY cluster, not just k8s-one).
	# The first live deploy (research/gitops-first-deploy.md) hit this
	# and was worked around BY HAND with --server-side; that workaround
	# was never folded back into this target, so every subsequent
	# `make argocd-install` would re-hit it. Server-side apply computes
	# no such annotation at all (it tracks field ownership instead), so
	# the size ceiling does not apply. --force-conflicts is needed for
	# re-applies (e.g. a version bump) so this target stays idempotent
	# even if a prior client-side apply (or a different field manager)
	# already owns some fields.
	kubectl apply --server-side --force-conflicts -k argocd/
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

## --- cert-manager-desec (real Let's Encrypt TLS; it.185 + deSEC) -----------
# The DNS-01 issuance chain for <name>.dedyn.io. See
# platform/cert-manager-desec/README.md for the full design (solver
# choice, PSL/rate-limit verdict, token handling, staging-first).
# Order: set-harbor-domain (once) -> desec-token -> dns-record ->
# certmanager-desec-deploy -> harbor-deploy.

.PHONY: set-harbor-domain
set-harbor-domain: ## One-shot: rewrite the harbor.k8s-one-onedata.dedyn.io placeholder repo-wide to DOMAIN=harbor.<name>.dedyn.io (then review `git diff` + commit).
	@if [ -z "$(DOMAIN)" ] || echo "$(DOMAIN)" | grep -q "CHANGEME"; then \
		echo "usage: make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io" >&2; exit 1; fi
	@echo "$(DOMAIN)" | grep -Eq '^harbor\.[a-z0-9-]+\.dedyn\.io$$' || \
		{ echo "DOMAIN must look like harbor.<name>.dedyn.io (got: $(DOMAIN))" >&2; exit 1; }
	@files="$$(git grep -l 'harbor\.CHANGEME\.dedyn\.io' -- . || true)"; \
	if [ -z "$$files" ]; then echo "No harbor.k8s-one-onedata.dedyn.io placeholders left -- already set?"; exit 0; fi; \
	echo "$$files" | xargs sed -i "s/harbor\.CHANGEME\.dedyn\.io/$(DOMAIN)/g"; \
	echo "Rewrote placeholder in:"; echo "$$files" | sed 's/^/  /'; \
	echo "Review with 'git diff', then commit -- Argo syncs from git, not your working tree."

.PHONY: desec-token
desec-token: ## Create/update the desec-token Secret DIRECTLY on the cluster (TOKEN=... or DESEC_TOKEN env). The ONE real credential -- NEVER goes in git; see platform/cert-manager-desec/README.md.
	@if [ -z "$(TOKEN)" ]; then \
		echo "usage: make desec-token TOKEN=<desec-api-token>   (or: DESEC_TOKEN=... make desec-token)" >&2; \
		echo "The real deSEC token. It NEVER goes in git -- this target writes it straight to the cluster." >&2; exit 1; fi
	@kubectl -n $(CERT_MANAGER_NAMESPACE) create secret generic desec-token \
		--from-literal=token='$(TOKEN)' \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "secret/desec-token ready in namespace $(CERT_MANAGER_NAMESPACE) (never committed; placeholder shape: platform/cert-manager-desec/desec-token.placeholder.yaml)."

.PHONY: dns-record
dns-record: ## Idempotently PATCH the deSEC A rrset: $(HARBOR_DOMAIN) -> HARBOR_NODE_IP=<node-InternalIP> (DESEC_TOKEN env or TOKEN=...). Re-run any time, e.g. to re-point after a node loss.
	@if echo "$(HARBOR_DOMAIN)" | grep -q "CHANGEME"; then \
		echo "HARBOR_DOMAIN still has the CHANGEME placeholder -- run 'make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io' first (and commit)." >&2; exit 1; fi
	@if [ "$(HARBOR_NODE_IP)" = "CHANGEME" ]; then \
		echo "usage: make dns-record HARBOR_NODE_IP=<node-InternalIP>   (any Ready node from 'kubectl get nodes -o wide')" >&2; exit 1; fi
	@if [ -z "$(TOKEN)" ]; then \
		echo "usage: DESEC_TOKEN=<desec-api-token> make dns-record HARBOR_NODE_IP=..." >&2; exit 1; fi
	@subname="$$(echo "$(HARBOR_DOMAIN)" | sed 's/\.$(DEDYN_DOMAIN)$$//')"; \
	payload="$$(jq -n --arg s "$$subname" --arg ip "$(HARBOR_NODE_IP)" \
		'[{subname: $$s, type: "A", ttl: 3600, records: [$$ip]}]')"; \
	echo "PATCH https://desec.io/api/v1/domains/$(DEDYN_DOMAIN)/rrsets/  ($$subname A -> $(HARBOR_NODE_IP), ttl 3600)"; \
	curl -fsS -X PATCH "https://desec.io/api/v1/domains/$(DEDYN_DOMAIN)/rrsets/" \
		-H "Authorization: Token $(TOKEN)" \
		-H "Content-Type: application/json" \
		--data "$$payload" | jq .
	@echo "Done (deSEC bulk PATCH is create-or-update, atomic, safe to re-run; ttl 3600 = deSEC's minimum)."

.PHONY: certmanager-desec-deploy
certmanager-desec-deploy: ## Apply the cert-manager-desec platform Application (GATED -- requires make argocd-install first; deploy AFTER desec-token + dns-record, BEFORE harbor-deploy).
	kubectl apply -f applications/platform/cert-manager-desec.yaml

## --- onedata-dev-ca (cluster-singleton platform app; design it.194-196/200/203) ---
# The shared development CA every dev landscape's managed Onezone/
# Oneprovider CRs can point spec.tls.issuerRef at (kind: ClusterIssuer)
# + spec.tls.trustIssuerCA: true, instead of always needing a public
# Let's Encrypt name. Independent of the mandatory landscape sequence
# and of the Harbor/cert-manager-desec chain -- only needs Argo CD to
# already exist. See platform/onedata-dev-ca/README.md for the full
# design (why a third ClusterIssuer, why it deploys into the
# pre-existing cert-manager namespace, rotation caveats).

.PHONY: dev-ca-deploy
dev-ca-deploy: ## Apply the onedata-dev-ca platform Application (GATED -- requires make argocd-install first; independent of Harbor/cert-manager-desec).
	kubectl apply -f applications/platform/onedata-dev-ca.yaml

## --- Harbor (cluster-singleton platform app; it.178/179/183 + it.185 TLS) ---
# Independent of the mandatory landscape sequence -- only needs Argo CD
# to already exist, PLUS (since TLS-v2) the cert-manager-desec chain
# above. See platform/harbor/README.md for the full design and the
# top-level README's "Harbor: proxy-cache + dev push target" section
# for the landscape-side consumption patterns.

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
harbor-ui: ## Port-forward the Harbor UI to https://localhost:8443 (localhost only). Expect a browser name-mismatch warning: the cert's SAN is $(HARBOR_DOMAIN), not localhost -- benign for a port-forward. Login: admin / harbor-admin-secret's HARBOR_ADMIN_PASSWORD.
	@echo "Harbor UI -> https://localhost:8443  (cert SAN is $(HARBOR_DOMAIN); the localhost mismatch warning is expected. Ctrl-C to stop)"
	kubectl -n $(HARBOR_NAMESPACE) port-forward svc/harbor 8443:443

# `harbor-configure-insecure-registry` is GONE (it.185 TLS-v2): the
# Let's Encrypt cert on $(HARBOR_HOST) is natively trusted by docker
# and containerd, so there is no insecure registry to configure. If
# you MUST run plaintext HTTP again, the old target + script live in
# git history (commit a76bc97, scripts/configure-docker-insecure-registry.sh).

.PHONY: harbor-login
harbor-login: ## docker login to Harbor's `dev` project from large-dev, using the harbor-dev-robot account. HTTPS with a real LE cert -- no insecure-registry config needed anywhere.
	@if echo "$(HARBOR_HOST)" | grep -q "CHANGEME"; then echo "HARBOR_DOMAIN still has the CHANGEME placeholder -- run 'make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io' first." >&2; exit 1; fi
	@user="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.username}' | base64 -d)"; \
	pass="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.password}' | base64 -d)"; \
	echo "$$pass" | docker login "$(HARBOR_HOST)" -u "$$user" --password-stdin

.PHONY: harbor-push
harbor-push: ## Tag + push IMAGE=<local-image:tag> into Harbor's `dev` project (via $(HARBOR_HOST)). Requires make harbor-login first.
	@if [ -z "$(IMAGE)" ] || echo "$(HARBOR_HOST)" | grep -q "CHANGEME"; then echo "usage: make harbor-push IMAGE=<local-image:tag>   (after set-harbor-domain + harbor-login)" >&2; exit 1; fi
	@repo="$$(echo "$(IMAGE)" | sed 's/^.*\///')"; \
	target="$(HARBOR_HOST)/dev/$${repo}"; \
	echo "docker tag $(IMAGE) $${target}"; \
	docker tag "$(IMAGE)" "$${target}"; \
	echo "docker push $${target}"; \
	docker push "$${target}"

.PHONY: harbor-pull-secret
harbor-pull-secret: ## Create/update the harbor-dev-pull imagePullSecret (from harbor-dev-robot) in namespace NS, for a landscape pulling from Harbor's private `dev` project. Uses $(HARBOR_HOST) -- the LE cert covers the public name, NOT *.svc.cluster.local, so in-cluster pulls use the same public name too.
	@if [ -z "$(NS)" ]; then echo "usage: make harbor-pull-secret NS=<landscape-namespace>" >&2; exit 1; fi
	@if echo "$(HARBOR_HOST)" | grep -q "CHANGEME"; then echo "HARBOR_DOMAIN still has the CHANGEME placeholder -- run 'make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io' first." >&2; exit 1; fi
	@user="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.username}' | base64 -d)"; \
	pass="$$(kubectl -n $(HARBOR_NAMESPACE) get secret harbor-dev-robot -o jsonpath='{.data.password}' | base64 -d)"; \
	kubectl -n "$(NS)" create secret docker-registry $(HARBOR_PULL_SECRET_NAME) \
		--docker-server="$(HARBOR_HOST)" \
		--docker-username="$$user" \
		--docker-password="$$pass" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "secret/$(HARBOR_PULL_SECRET_NAME) ready in namespace $(NS). Reference it via imagePullSecrets on the consuming ServiceAccount/Pod."

## --- Upstream-image snapshot discipline (it.230 standing policy) -----------
# NEVER deploy a mutable Onedata tag (`develop`/`latest` on
# docker.onedata.org, or a Docker-Hub release tag pulled via
# dockerhub-proxy) straight into a landscape -- Onedata's `develop` ==
# `latest`, contents unknown/same-day-unstable (it.229: two local
# `:develop` pulls 3 days apart already differed). Instead, snapshot the
# EXACT image you just validated into Harbor's private `dev` project
# under a DATED tag; a landscape pins that dated tag, never the mutable
# one. Updating an existing dated snapshot is a conscious decision
# (FORCE=1), never a side effect of re-running this target.
SNAPSHOTS_FILE ?= images/SNAPSHOTS.md

.PHONY: snapshot-image
snapshot-image: ## Snapshot SRC (a mutable upstream image ref) into Harbor's `dev` project as NAME:<src-tag>-DATE (it.230). Requires make harbor-login first. NOPULL=1 skips the pull and snapshots whatever SRC already resolves to locally (use when SRC was pulled+validated earlier and a fresh pull could silently swap bits under a mutable tag). DATE defaults to today (YYYYMMDD). FORCE=1 overwrites an existing dated tag -- otherwise the target refuses, since overwriting a snapshot is meant to be a conscious decision, not an accident.
	@if [ -z "$(SRC)" ] || [ -z "$(NAME)" ]; then \
		echo "usage: make snapshot-image SRC=<source-image-ref> NAME=<harbor-dev-repo-name> [DATE=YYYYMMDD] [NOPULL=1] [FORCE=1]" >&2; exit 1; fi
	@if echo "$(HARBOR_HOST)" | grep -q "CHANGEME"; then echo "HARBOR_DOMAIN still has the CHANGEME placeholder -- run 'make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io' first." >&2; exit 1; fi
	@srctag="$$(echo '$(SRC)' | sed -n 's/.*:\([^:\/]*\)$$/\1/p')"; \
	if [ -z "$$srctag" ]; then srctag="latest"; fi; \
	snapdate="$(DATE)"; if [ -z "$$snapdate" ]; then snapdate="$$(date +%Y%m%d)"; fi; \
	target_tag="$${srctag}-$${snapdate}"; \
	target="$(HARBOR_HOST)/dev/$(NAME):$${target_tag}"; \
	echo "=== snapshot-image: $(SRC) -> $${target} ==="; \
	if [ "$(NOPULL)" = "1" ]; then \
		echo "NOPULL=1 -- using whatever $(SRC) already resolves to in the local docker daemon (NOT re-pulling, to avoid silently swapping bits under a mutable tag)."; \
	else \
		echo "+ docker pull $(SRC)"; docker pull "$(SRC)"; \
	fi; \
	if ! docker image inspect "$(SRC)" >/dev/null 2>&1; then \
		echo "SRC image $(SRC) is not present in the local docker daemon (pull it first, or drop NOPULL=1)." >&2; exit 1; fi; \
	if [ "$(FORCE)" != "1" ] && docker manifest inspect "$${target}" >/dev/null 2>&1; then \
		echo "REFUSING: $${target} already exists in Harbor. Overwriting a dated snapshot is a conscious decision (it.230) -- re-run with FORCE=1 if that is genuinely intended." >&2; exit 1; fi; \
	echo "+ docker tag $(SRC) $${target}"; docker tag "$(SRC)" "$${target}"; \
	echo "+ docker push $${target}"; \
	push_out="$$(docker push "$${target}" 2>&1)"; echo "$$push_out"; \
	digest="$$(echo "$$push_out" | grep -oE 'sha256:[0-9a-f]{64}' | tail -1)"; \
	[ -n "$$digest" ] || digest="UNKNOWN (not found in push output -- check manually: docker manifest inspect $${target})"; \
	image_id="$$(docker image inspect "$(SRC)" --format '{{.Id}}')"; \
	created="$$(docker image inspect "$(SRC)" --format '{{.Created}}')"; \
	echo; echo "Captured:"; \
	echo "  source ref     : $(SRC)"; \
	echo "  harbor target  : $${target}"; \
	echo "  imageID        : $$image_id"; \
	echo "  upstream build : $$created"; \
	echo "  repo digest    : $$digest"; \
	mkdir -p "$$(dirname $(SNAPSHOTS_FILE))"; \
	if [ ! -f "$(SNAPSHOTS_FILE)" ]; then \
		{ echo "# Upstream-image snapshots (it.230)"; echo; \
		  echo "See the policy statement in this repo's top-level README / the design log (it.230)."; echo; \
		  echo "| Snapshot date | Source ref | Harbor target | Upstream build date | Image ID | Digest | Validated by |"; \
		  echo "|---|---|---|---|---|---|---|"; \
		} > "$(SNAPSHOTS_FILE)"; \
	fi; \
	echo "| $$snapdate | \`$(SRC)\` | \`$${target}\` | $$created | \`$$image_id\` | \`$$digest\` | TODO: fill in before committing | " >> "$(SNAPSHOTS_FILE)"; \
	echo; echo "Appended a row to $(SNAPSHOTS_FILE) -- EDIT the 'Validated by' column (evidence doc / landscape pointer) before committing."

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
validate-platform: ## kustomize build + dry-run every platform/<app>/ (platform/harbor/, platform/cert-manager-desec/).
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
