#!/usr/bin/env bash
# Day-2 companion script for the sv-posix-multinode landscape -- applies
# the CRs whose spec depends on a value that does not exist until the
# managed Onezone/Oneprovider (wave 2's onezone.yaml/oneprovider.yaml,
# already synced by Argo by the time you run this) reach Ready:
#
#   StorageBackend.spec.onepanelEndpoint and User.spec.onepanelEndpoint
#   are both the managed Oneprovider/Onezone's onepanel POD IP
#   (internal/controller/oneprovider_managed.go's refreshManagedEndpoint,
#   deliberately pod-IP-based rather than Service-DNS-based -- verified
#   by source read during this scaffold). That value cannot be committed
#   to git; it is read live here, exactly the same drive-first pattern
#   demo/landscape-3p's and demo/landscape-max's own 04/05 apply scripts
#   already use and document. See the top-level README's "Known gaps"
#   section for why this is not (yet) folded into the Argo sync itself.
#
# Run this ONCE, after `make deploy-landscape NAME=sv-posix-multinode
# VERSION=v1` and after both `onezone/zone` and `oneprovider/provider`
# report `Ready` (watch with `kubectl get onezone,oneprovider -n
# sv-posix-multinode -w`, or let this script's own `kubectl wait` calls
# block for you).
#
# APPLY_CMD override exists for offline validation (this script's own
# `make validate-landscapes` companion target renders every heredoc with
# APPLY_CMD=cat and dummy *_ENDPOINT env vars, exactly like
# demo/landscape-max/04-storagebackends.sh's own convention) -- normal
# use sets neither.
set -euo pipefail

NAMESPACE="${NAMESPACE:-sv-posix-multinode}"
TIMEOUT="${WAIT_TIMEOUT:-600s}"
APPLY_CMD="${APPLY_CMD:-kubectl apply -f -}"

if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
  echo "[apply-dependent-crs] waiting for oneprovider/provider to be Ready in ${NAMESPACE}..." >&2
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "oneprovider/provider" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
fi
PROVIDER_ENDPOINT="${PROVIDER_ONEPANEL_ENDPOINT:-$(kubectl get oneprovider provider -n "${NAMESPACE}" -o jsonpath='{.status.managedOnepanelEndpoint}')}"
if [ -z "${PROVIDER_ENDPOINT}" ]; then
  echo "oneprovider/provider has no status.managedOnepanelEndpoint yet -- is it Ready?" >&2
  exit 1
fi
echo "[apply-dependent-crs] provider onepanel endpoint: ${PROVIDER_ENDPOINT}" >&2

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: StorageBackend
metadata:
  name: provider-posix
  namespace: ${NAMESPACE}
spec:
  name: "provider-posix"
  type: posix
  providerRef:
    name: provider
  onepanelEndpoint: "${PROVIDER_ENDPOINT}"
  onepanelCredentialsSecretRef:
    name: provider-onepanel-creds
  params:
    mountPoint: /volumes/posix
EOF

if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
  echo "[apply-dependent-crs] waiting for onezone/zone to be Ready in ${NAMESPACE}..." >&2
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "onezone/zone" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
fi
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

  echo "[apply-dependent-crs] waiting for storagebackend/provider-posix to be Ready..." >&2
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "storagebackend/provider-posix" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
fi

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: Space
metadata:
  name: sv-space
  namespace: ${NAMESPACE}
spec:
  name: "sv-space"
  onezoneRef:
    endpoint: zone-onezone.${NAMESPACE}.svc.cluster.local
  ownerRef:
    name: scientist
EOF

if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
  echo "[apply-dependent-crs] waiting for space/sv-space to be Ready..." >&2
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "space/sv-space" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
fi

echo "---"
cat <<EOF | ${APPLY_CMD}
apiVersion: onedata.org/v1alpha1
kind: Support
metadata:
  name: sv-support
  namespace: ${NAMESPACE}
spec:
  spaceRef:
    name: sv-space
  providerRef:
    name: provider
  storageRef:
    name: provider-posix
  size: 10Gi
EOF

if [ "${APPLY_CMD}" = "kubectl apply -f -" ]; then
  echo "[apply-dependent-crs] waiting for support/sv-support to be Ready..." >&2
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "support/sv-support" -n "${NAMESPACE}" --timeout="${TIMEOUT}"
  echo "[apply-dependent-crs] done -- landscape fully Ready." >&2
fi
