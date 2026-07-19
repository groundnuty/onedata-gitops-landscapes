#!/usr/bin/env bash
# Day-2 companion script for sv-federation/v1 -- same drive-first
# pattern as every other landscape's apply-dependent-crs.sh (User/
# StorageBackend/Space/Support/Oneclient controllers are documented as
# TEMPORARY/MVP/drive-first: they do not yet resolve a managed
# Onezone/Oneprovider CR's own status, so onepanelEndpoint/
# onezoneRef.endpoint fields cannot be committed to git). This one is
# doubled where the landscape itself is doubled: TWO StorageBackends
# (one per provider) and TWO Supports (one per (space, provider) pair
# -- posing no VFS-5497 same-provider conflict, since the two Supports
# target DIFFERENT providers), plus ONE Oneclient against provider-a
# (the scenario-1 re-validation the mission also asked for).
#
# Run this ONCE, after `make deploy-landscape NAME=sv-federation
# VERSION=v1` and after onezone/zone AND BOTH oneprovider/provider-a,
# oneprovider/provider-b report `Ready` in the sv-federation namespace.
#
# APPLY_CMD override exists for offline validation (this script's own
# `make validate-landscapes` companion target renders every heredoc
# with APPLY_CMD=cat and dummy *_ENDPOINT env vars) -- normal use sets
# neither.
set -euo pipefail

NAMESPACE="${NAMESPACE:-sv-federation}"
TIMEOUT="${WAIT_TIMEOUT:-600s}"
APPLY_CMD="${APPLY_CMD:-kubectl apply -f -}"

wait_ready() {
  # $1 = kind/name
  if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
    echo "[apply-dependent-crs] waiting for ${1} to be Ready in ${NAMESPACE}..." >&2
    kubectl wait --for=jsonpath='{.status.phase}'=Ready "${1}" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
  fi
}

wait_ready "oneprovider/provider-a"
wait_ready "oneprovider/provider-b"

PROVIDER_A_ENDPOINT="${PROVIDER_A_ONEPANEL_ENDPOINT:-$(kubectl get oneprovider provider-a -n "${NAMESPACE}" -o jsonpath='{.status.managedOnepanelEndpoint}')}"
PROVIDER_B_ENDPOINT="${PROVIDER_B_ONEPANEL_ENDPOINT:-$(kubectl get oneprovider provider-b -n "${NAMESPACE}" -o jsonpath='{.status.managedOnepanelEndpoint}')}"
if [ -z "${PROVIDER_A_ENDPOINT}" ] || [ -z "${PROVIDER_B_ENDPOINT}" ]; then
  echo "one of provider-a/provider-b has no status.managedOnepanelEndpoint yet -- are they Ready?" >&2
  exit 1
fi
echo "[apply-dependent-crs] provider-a onepanel endpoint: ${PROVIDER_A_ENDPOINT}" >&2
echo "[apply-dependent-crs] provider-b onepanel endpoint: ${PROVIDER_B_ENDPOINT}" >&2

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: StorageBackend
metadata:
  name: provider-a-posix
  namespace: ${NAMESPACE}
spec:
  name: "provider-a-posix"
  type: posix
  providerRef:
    name: provider-a
  onepanelEndpoint: "${PROVIDER_A_ENDPOINT}"
  onepanelCredentialsSecretRef:
    name: provider-a-onepanel-creds
  params:
    mountPoint: /volumes/posix
EOF

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: StorageBackend
metadata:
  name: provider-b-posix
  namespace: ${NAMESPACE}
spec:
  name: "provider-b-posix"
  type: posix
  providerRef:
    name: provider-b
  onepanelEndpoint: "${PROVIDER_B_ENDPOINT}"
  onepanelCredentialsSecretRef:
    name: provider-b-onepanel-creds
  params:
    mountPoint: /volumes/posix
EOF

wait_ready "onezone/zone"
ZONE_ENDPOINT="${ZONE_ONEPANEL_ENDPOINT:-$(kubectl get onezone zone -n "${NAMESPACE}" -o jsonpath='{.status.managedOnepanelEndpoint}')}"
if [ -z "${ZONE_ENDPOINT}" ]; then
  echo "onezone/zone has no status.managedOnepanelEndpoint yet -- is it Ready?" >&2
  exit 1
fi
echo "[apply-dependent-crs] zone onepanel endpoint: ${ZONE_ENDPOINT}" >&2

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: User
metadata:
  name: scientist
  namespace: ${NAMESPACE}
spec:
  username: scientist
  onezoneRef:
    name: zone
  onepanelEndpoint: "${ZONE_ENDPOINT}"
  onepanelCredentialsSecretRef:
    name: onezone-onepanel-creds
  attributesSecretRef:
    name: scientist-attrs
EOF

if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
  echo "[apply-dependent-crs] waiting for user/scientist to mint its access token..." >&2
  for _ in $(seq 1 60); do
    TOKREF="$(kubectl get user scientist -n "${NAMESPACE}" -o jsonpath='{.status.accessTokenSecretRef.name}' 2>/dev/null || true)"
    [ -n "${TOKREF}" ] && break
    sleep 5
  done
  if [ -z "${TOKREF:-}" ]; then
    echo "user/scientist never populated status.accessTokenSecretRef -- check its Conditions" >&2
    exit 1
  fi
  echo "[apply-dependent-crs] user access token secret: ${TOKREF}" >&2

  wait_ready "storagebackend/provider-a-posix"
  wait_ready "storagebackend/provider-b-posix"
fi

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: Space
metadata:
  name: fed-space
  namespace: ${NAMESPACE}
spec:
  name: "fed-space"
  onezoneRef:
    endpoint: zone-onezone.${NAMESPACE}.svc.cluster.local
  ownerRef:
    name: scientist
EOF

wait_ready "space/fed-space"

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: Support
metadata:
  name: fed-support-a
  namespace: ${NAMESPACE}
spec:
  spaceRef:
    name: fed-space
  providerRef:
    name: provider-a
  storageRef:
    name: provider-a-posix
  size: 10Gi
EOF

wait_ready "support/fed-support-a"

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: Support
metadata:
  name: fed-support-b
  namespace: ${NAMESPACE}
spec:
  spaceRef:
    name: fed-space
  providerRef:
    name: provider-b
  storageRef:
    name: provider-b-posix
  size: 10Gi
EOF

wait_ready "support/fed-support-b"

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: Oneclient
metadata:
  name: fed-client-a
  namespace: ${NAMESPACE}
spec:
  oneproviderRef:
    name: provider-a
  userRef:
    name: scientist
EOF

if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
  echo "[apply-dependent-crs] waiting for oneclient/fed-client-a to be Ready..." >&2
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "oneclient/fed-client-a" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
  echo "[apply-dependent-crs] done -- landscape fully Ready, space fed-space is dual-supported." >&2
fi
