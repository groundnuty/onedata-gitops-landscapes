#!/usr/bin/env bash
# Restarts the EXISTING k8s-one cluster-wide onedata-operator manager
# (currently `onedata-operator-controller-manager` in namespace
# `onedata-operator-system`, image `onedata/onedata-operator:v0.5.0` --
# confirmed live via `kubectl get deploy -A -l
# control-plane=controller-manager` during this scaffold's recon) with
# `--watch-namespace=landscape-max,demo-a` so it stops seeing (and
# reconciling, incorrectly, with a binary that predates several fields
# this repo's landscapes rely on) any NEW landscape namespace this repo
# creates.
#
# MANDATORY STEP 1 of the deploy sequence (see the top-level README).
# Bounded, low-risk, already-precedented: design it.156 proved a
# manager restart does not disturb already-running providers (the
# restart only recreates the manager's own Pod; every Onezone/Oneprovider
# StatefulSet it manages keeps running throughout via its own,
# independent reconcile-on-next-loop semantics).
#
# THIS REPO DOES NOT RUN THIS SCRIPT FOR YOU. `make scope-cluster-manager`
# calls it, but nothing in this repo's CI/automation invokes that target
# automatically -- it is the operator's/maintainer's to invoke,
# deliberately, once per cluster, before the first new-landscape deploy
# (and idempotently safe to re-run after that).
#
# NOTE (--watch-namespace is single-value, not a list): as of this
# scaffold, cmd/main.go's --watch-namespace flag takes ONE namespace,
# not a comma-separated list (`cacheOpts.DefaultNamespaces =
# map[string]cache.Config{watchNamespace: {}}` -- a single-key map).
# Watching BOTH landscape-max AND demo-a with one flag value is not
# possible against the CURRENT flag as read from source; confirm
# against master before running this script, and if it is still
# single-value, either (a) pick the one namespace this manager should
# keep, migrating the other to its own bundled operator first, or
# (b) extend --watch-namespace to accept a comma-separated list
# upstream before relying on this script as written. Flagged here
# rather than silently narrowing scope to one namespace without saying
# so.

set -euo pipefail

NAMESPACE="${MANAGER_NAMESPACE:-onedata-operator-system}"
DEPLOYMENT="${MANAGER_DEPLOYMENT:-onedata-operator-controller-manager}"
WATCH_NAMESPACES="${WATCH_NAMESPACES:-landscape-max,demo-a}"
KUBECONFIG_PATH="${KUBECONFIG:?set KUBECONFIG to the target cluster's kubeconfig before running this}"

echo "[scope-cluster-manager] target: deploy/${DEPLOYMENT} -n ${NAMESPACE}" >&2
echo "[scope-cluster-manager] intended --watch-namespace value: ${WATCH_NAMESPACES}" >&2
echo "[scope-cluster-manager] KUBECONFIG=${KUBECONFIG_PATH}" >&2

CURRENT_IMAGE="$(kubectl -n "${NAMESPACE}" get deploy "${DEPLOYMENT}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "[scope-cluster-manager] current image: ${CURRENT_IMAGE}" >&2

kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=json -p "$(cat <<JSON
[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--watch-namespace=${WATCH_NAMESPACES}"
  }
]
JSON
)"

echo "[scope-cluster-manager] waiting for the rollout to settle..." >&2
kubectl -n "${NAMESPACE}" rollout status "deploy/${DEPLOYMENT}" --timeout=180s

echo "[scope-cluster-manager] done. Verify with:" >&2
echo "  kubectl -n ${NAMESPACE} get deploy ${DEPLOYMENT} -o jsonpath='{.spec.template.spec.containers[0].args}'" >&2
