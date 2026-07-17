#!/usr/bin/env bash
# Configures large-dev's OWN docker daemon (the one `make harbor-login`/
# `make harbor-push` use, pushing FROM large-dev INTO Harbor's `dev`
# project) to treat Harbor's NodePort endpoint as an insecure registry.
#
# Needed because platform/harbor's v1 exposure is HTTP-internal, no TLS
# (see platform/harbor/README.md's "Exposure and TLS" section) --
# docker refuses to talk to a plaintext registry by default, and this
# is true REGARDLESS of whether the plaintext is "no TLS" or "TLS with
# an untrusted self-signed CA" (docker would need `--insecure-registry`
# either way; disabling TLS entirely doesn't cost anything extra here).
#
# NOT run automatically by anything else in this repo -- `make
# harbor-configure-insecure-registry` is the one explicit trigger, and
# even that only runs when a maintainer types it. This script uses
# `sudo` twice (read + rewrite /etc/docker/daemon.json, then restart
# the docker daemon) -- both are visible below, nothing hidden. The
# docker restart interrupts any in-flight local docker builds/pulls on
# this host; run it when you're ready for that.
#
# SCOPE NOTE (read this before assuming this script "solves Harbor
# access"): this ONLY configures large-dev's own docker CLI/daemon for
# pushing/pulling from a shell on large-dev. It does NOT touch any of
# the 22 k8s-one nodes' containerd (k3s) registry trust config -- an
# in-cluster pod actually pulling an image via a Harbor-prefixed
# reference (the README's kustomize image-prefix overlay pattern, or a
# pod using the harbor-dev-pull imagePullSecret) needs EACH node's k3s
# containerd to trust Harbor's endpoint too (typically via
# /etc/rancher/k3s/registries.yaml's `configs: "<host>": tls: {
# insecure_skip_verify: true }` or an http-endpoint mirror entry,
# depending on the exact k3s/containerd version). That is a real,
# separate, 22-node operational step -- NOT automated by this script or
# by anything else in this build (it.178 explicitly deferred "node-
# containerd mirror surgery" out of v1; this script only covers the
# large-dev-push side of that same underlying HTTP-registry-trust
# problem). See platform/harbor/README.md's "Known gaps" section.

set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:?set to <a-k8s-one-node-ip>:30002, e.g. 10.87.23.54:30002 -- see the Exposure section in platform/harbor/README.md}"
DAEMON_JSON="${DAEMON_JSON:-/etc/docker/daemon.json}"

echo "[configure-docker-insecure-registry] target: ${HARBOR_HOST}" >&2
echo "[configure-docker-insecure-registry] daemon.json: ${DAEMON_JSON}" >&2

current="{}"
if sudo test -f "${DAEMON_JSON}"; then
  current="$(sudo cat "${DAEMON_JSON}")"
fi

updated="$(echo "${current}" | jq --arg host "${HARBOR_HOST}" '
  .["insecure-registries"] = ((.["insecure-registries"] // []) + [$host] | unique)
')"

if [ "$(echo "${current}" | jq -S .)" = "$(echo "${updated}" | jq -S .)" ]; then
  echo "[configure-docker-insecure-registry] ${HARBOR_HOST} already present in ${DAEMON_JSON} -- no change." >&2
  exit 0
fi

echo "${updated}" | sudo tee "${DAEMON_JSON}" > /dev/null
echo "[configure-docker-insecure-registry] wrote ${DAEMON_JSON}. Restarting docker..." >&2
sudo systemctl restart docker
echo "[configure-docker-insecure-registry] done. Verify with:" >&2
echo "  docker info | grep -A5 'Insecure Registries'" >&2
