#!/usr/bin/env bash
# Harbor config-as-code (it.179: "Harbor's config ... becomes
# declarative + versioned"). Runs INSIDE the cluster as the
# harbor-configure-projects Job (config/job.yaml, wave 1 -- after
# Harbor itself, wave 0, is healthy) via curl against Harbor's own
# REST API (v2.0). Every call below is idempotent: check-then-create,
# safe to run more than once (needed because a completed Kubernetes Job
# is otherwise immutable -- `make harbor-configure` re-runs this by
# deleting and recreating the Job object, see the top-level Makefile).
#
# Creates:
#   1. a Registry endpoint "dockerhub" (type docker-hub, anonymous --
#      no credential) that Harbor proxies Docker Hub through.
#   2. a public proxy-cache Project "dockerhub-proxy" backed by (1).
#   3. a private Project "dev" -- the push target for feature-branch
#      operator images AND maintainer-authorized patched Onedata images
#      (it.183).
#   4. a project-scoped Robot account (`robot$dev+large-dev-push`,
#      never-expiring) with push+pull rights on "dev" ONLY -- least
#      privilege, so large-dev's docker login never needs the admin
#      password.
#
# it.206 CORRECTION (read before touching step 4): the original
# assumption here -- that Harbor's RobotCreate API honors a
# caller-supplied `secret` field, so the robot's password could be a
# plain pre-committed demo string -- was WRONG. Live testing against
# this cluster's actual Harbor (goharbor/harbor-core:v2.14.4) plus
# reading its source (src/controller/robot/controller.go's Create())
# confirmed: the server ALWAYS calls CreateSec() and never reads the
# request's Secret field. A robot's real secret is generated
# server-side and shown EXACTLY ONCE, in the 201 response body -- there
# is no create-time or update-time way to pin it, and no
# `/robots/{id}/sec` endpoint in this version either (checked live,
# 404). So step 4 below is no longer "create with a known secret" --
# it's "create (or rotate), CAPTURE the one-time secret, and WRITE it
# to the harbor-dev-robot k8s Secret" via this Job's own
# ServiceAccount (config/rbac.yaml). See README.md's "Robot account and
# auth model" section for the full writeup.
#
# All four are look-before-you-create: re-running this script against
# an already-configured Harbor is a no-op (logged, not skipped
# silently) for every step.
set -euo pipefail

# kubectl (used only by step 4, to read/write the harbor-dev-robot
# Secret) wants a writable $HOME for its discovery/http cache dirs;
# the container's root filesystem is read-only (job.yaml's
# securityContext), but /tmp is a writable emptyDir.
export HOME=/tmp

HARBOR_URL="${HARBOR_URL:-http://harbor-core.onedata-gitops-harbor.svc.cluster.local}"
HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?set from the harbor-admin-secret Secret (HARBOR_ADMIN_PASSWORD key)}"
DOCKERHUB_REGISTRY_NAME="${DOCKERHUB_REGISTRY_NAME:-dockerhub}"
PROXY_PROJECT_NAME="${PROXY_PROJECT_NAME:-dockerhub-proxy}"
DEV_PROJECT_NAME="${DEV_PROJECT_NAME:-dev}"
ROBOT_SHORT_NAME="${ROBOT_SHORT_NAME:-large-dev-push}"
ROBOT_FULL_NAME="robot\$${DEV_PROJECT_NAME}+${ROBOT_SHORT_NAME}"
# The k8s Secret this script writes (never reads a secret value from
# it -- see the it.206 correction above). Namespace defaults to
# whatever namespace this Pod itself runs in (the projected
# ServiceAccount file), falling back to the well-known literal only if
# that file isn't there for some reason (e.g. run by hand off-cluster).
K8S_NAMESPACE="${K8S_NAMESPACE:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo onedata-gitops-harbor)}"
ROBOT_K8S_SECRET_NAME="${ROBOT_K8S_SECRET_NAME:-harbor-dev-robot}"

API="${HARBOR_URL%/}/api/v2.0"

log() { echo "[configure-harbor] $*" >&2; }

curl_auth() {
  curl -sS -u "${HARBOR_ADMIN_USER}:${HARBOR_ADMIN_PASSWORD}" -H 'Content-Type: application/json' "$@"
}

# --- 0. wait for Harbor to be reachable -------------------------------------
log "waiting for ${API}/health ..."
health_code=""
for _ in $(seq 1 60); do
  health_code="$(curl -sS -o /dev/null -w '%{http_code}' "${API}/health" || echo "000")"
  [ "${health_code}" = "200" ] && break
  sleep 5
done
if [ "${health_code}" != "200" ]; then
  log "FATAL: Harbor never reported healthy at ${API}/health (last HTTP code: ${health_code})"
  exit 1
fi
log "Harbor is healthy."

# --- helper: POST and extract the created resource's numeric id from the
# --- Location response header (Harbor's generic 201 has no body -- only
# --- robots' 201 does, handled separately below).
post_and_get_location_id() {
  local path="$1" payload="$2" headers_file status location
  headers_file="$(mktemp)"
  status="$(curl_auth -o /dev/null -D "${headers_file}" -w '%{http_code}' -X POST -d "${payload}" "${API}${path}")"
  if [ "${status}" != "201" ]; then
    log "FATAL: POST ${path} returned HTTP ${status}"
    cat "${headers_file}" >&2
    rm -f "${headers_file}"
    exit 1
  fi
  location="$(grep -i '^Location:' "${headers_file}" | tr -d '\r' | awk '{print $2}')"
  rm -f "${headers_file}"
  basename "${location}"
}

# --- helper: does the harbor-dev-robot k8s Secret already exist? -----------
k8s_secret_exists() {
  kubectl -n "${K8S_NAMESPACE}" get secret "${ROBOT_K8S_SECRET_NAME}" >/dev/null 2>&1
}

# --- helper: write/overwrite the harbor-dev-robot k8s Secret ---------------
write_k8s_secret() {
  local username="$1" password="$2"
  kubectl -n "${K8S_NAMESPACE}" create secret generic "${ROBOT_K8S_SECRET_NAME}" \
    --from-literal="username=${username}" \
    --from-literal="password=${password}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# --- helper: last-resort existing-robot-id lookup by direct ID scan -------
# Only used if the (verified-working, see below) list query somehow still
# misses a robot that a POST 409 says exists. Small dev-only Harbor
# instance -- a bounded scan of the first 200 ids is fast (in-cluster,
# no TLS) and only ever runs on this narrow fallback path.
find_robot_id_by_scan() {
  local id resp status body
  for id in $(seq 1 200); do
    resp="$(curl_auth -w '\n%{http_code}' "${API}/robots/${id}")"
    status="$(echo "${resp}" | tail -n1)"
    body="$(echo "${resp}" | sed '$d')"
    if [ "${status}" = "200" ] && [ "$(echo "${body}" | jq -r '.name')" = "${ROBOT_FULL_NAME}" ]; then
      echo "${id}"
      return 0
    fi
  done
  return 1
}

# --- 1. registry endpoint: Docker Hub, anonymous ----------------------------
log "checking for registry '${DOCKERHUB_REGISTRY_NAME}'..."
registry_id="$(curl_auth "${API}/registries?name=${DOCKERHUB_REGISTRY_NAME}" | jq -r '.[0].id // empty')"
if [ -n "${registry_id}" ]; then
  log "registry '${DOCKERHUB_REGISTRY_NAME}' already exists (id=${registry_id})"
else
  # NOTE on the url field (source-verified against goharbor/harbor
  # src/pkg/reg/adapter/dockerhub/{consts.go,adapter.go}): the type
  # docker-hub adapter's UI/EndpointPattern is FIXED to
  # "https://hub.docker.com" (consts.go's baseURL, used for the
  # DockerHub-specific namespace/tag-listing REST API), while actual
  # proxy-cache image PULLS always go through a separately hardcoded
  # `registryURL = "https://registry-1.docker.io"` constant regardless
  # of this field's value (adapter.go's newAdapter() builds an inner
  # native.Adapter pointed at that constant, not at registry.URL).
  # registry-1.docker.io -- the URL this build was originally briefed
  # to use -- IS where every proxied pull actually lands; hub.docker.com
  # here only matches Harbor's own documented/UI convention for what
  # you type into this field. No functional difference either way.
  registry_payload="$(jq -n --arg name "${DOCKERHUB_REGISTRY_NAME}" '{
    name: $name,
    url: "https://hub.docker.com",
    type: "docker-hub",
    insecure: false,
    credential: {type: "", access_key: "", access_secret: ""}
  }')"
  registry_id="$(post_and_get_location_id /registries "${registry_payload}")"
  log "created registry '${DOCKERHUB_REGISTRY_NAME}' (id=${registry_id})"
fi

# --- 2. proxy-cache project: dockerhub-proxy --------------------------------
log "checking for project '${PROXY_PROJECT_NAME}'..."
if [ "$(curl_auth "${API}/projects?name=${PROXY_PROJECT_NAME}" | jq -r 'length')" -gt 0 ]; then
  log "project '${PROXY_PROJECT_NAME}' already exists"
else
  # public=true: the whole point is frictionless pulls from any of the
  # 22 nodes without per-node Harbor credentials (it.178).
  proxy_payload="$(jq -n --arg name "${PROXY_PROJECT_NAME}" --argjson registry_id "${registry_id}" '{
    project_name: $name,
    metadata: {public: "true"},
    registry_id: $registry_id
  }')"
  proxy_id="$(post_and_get_location_id /projects "${proxy_payload}")"
  log "created project '${PROXY_PROJECT_NAME}' (id=${proxy_id}, proxy-cache -> registry id=${registry_id})"
fi

# --- 3. private push-target project: dev ------------------------------------
log "checking for project '${DEV_PROJECT_NAME}'..."
# NOTE: Harbor's Project object's identifier field is `project_id`, NOT
# `id` (unlike Robot/Registry objects, which really do use `id` --
# confirmed live: an earlier `.id` here silently matched nothing,
# jq's `// empty` swallowed it, and the script mis-detected an
# existing "dev" project as absent on every run).
dev_id="$(curl_auth "${API}/projects?name=${DEV_PROJECT_NAME}" | jq -r '.[0].project_id // empty')"
if [ -n "${dev_id}" ]; then
  log "project '${DEV_PROJECT_NAME}' already exists (id=${dev_id})"
else
  # private (public=false): feature-branch operator images AND
  # maintainer-authorized patched Onedata core images (it.183) live
  # here. NEVER pushed onward to any public/Onedata registry -- see
  # README.md's "it.183 exception" section for the full rule.
  dev_payload="$(jq -n --arg name "${DEV_PROJECT_NAME}" '{
    project_name: $name,
    metadata: {public: "false"}
  }')"
  dev_id="$(post_and_get_location_id /projects "${dev_payload}")"
  log "created project '${DEV_PROJECT_NAME}' (id=${dev_id}, private)"
fi

# --- 4. project-scoped robot account for push access ------------------------
# See the it.206 CORRECTION at the top of this file: the secret is
# never caller-supplied. The k8s Secret's mere PRESENCE is the only
# thing this script can use as "a previous run captured a working
# secret" -- so that is exactly the idempotency signal used below.
log "checking whether k8s Secret '${ROBOT_K8S_SECRET_NAME}' (ns ${K8S_NAMESPACE}) already holds a captured robot secret..."
if k8s_secret_exists; then
  log "k8s Secret '${ROBOT_K8S_SECRET_NAME}' already present -- a previous run already captured a working secret for '${ROBOT_FULL_NAME}'. Leaving the robot account untouched."
else
  log "k8s Secret '${ROBOT_K8S_SECRET_NAME}' is absent -- any existing robot's secret is unknown/unrecoverable (Harbor never re-shows it). Locating an existing robot to rotate, if any..."

  # Verified-working existence query for THIS Harbor version: a bare
  # `q=name=<full name>` (what earlier code here used) reliably returns
  # zero results regardless of encoding/case -- confirmed live and by
  # exercising the API directly. Scoping by Level+ProjectID and
  # fuzzy-matching the short name, then filtering to an EXACT name
  # match client-side in jq, is what actually finds it.
  existing_id="$(curl_auth -G --data-urlencode "q=Level=project,ProjectID=${dev_id},name=~${ROBOT_SHORT_NAME}" "${API}/robots" \
    | jq -r --arg full "${ROBOT_FULL_NAME}" '[.[] | select(.name == $full)][0].id // empty')"

  if [ -z "${existing_id}" ]; then
    # Defense in depth: if this also misses (and a create below then
    # 409s), fall back to a direct ID scan rather than treating the
    # conflict as fatal.
    existing_id="$(find_robot_id_by_scan || true)"
    [ -n "${existing_id}" ] && log "found existing robot via ID-scan fallback (id=${existing_id})"
  fi

  if [ -n "${existing_id}" ]; then
    log "deleting stale robot account '${ROBOT_FULL_NAME}' (id=${existing_id}) -- its secret is unrecoverable, rotating..."
    del_status="$(curl_auth -o /dev/null -w '%{http_code}' -X DELETE "${API}/robots/${existing_id}")"
    if [ "${del_status}" != "200" ] && [ "${del_status}" != "204" ]; then
      log "FATAL: DELETE /robots/${existing_id} returned HTTP ${del_status}"
      exit 1
    fi
    log "deleted stale robot account (id=${existing_id})"
  else
    log "no existing robot account found -- creating fresh."
  fi

  robot_payload="$(jq -n \
    --arg name "${ROBOT_SHORT_NAME}" \
    --arg ns "${DEV_PROJECT_NAME}" \
    '{
      name: $name,
      description: "push/pull from large-dev docker for feature-branch + patched-core images (it.183)",
      level: "project",
      duration: -1,
      permissions: [
        {
          kind: "project",
          namespace: $ns,
          access: [
            {resource: "repository", action: "push"},
            {resource: "repository", action: "pull"},
            {resource: "artifact", action: "read"},
            {resource: "tag", action: "create"}
          ]
        }
      ]
    }')"
  # NOTE: no "secret" field in the payload -- Harbor (this version)
  # ignores it entirely (see the it.206 CORRECTION above); sending one
  # would be dead weight, not a real credential pin.
  robot_response="$(curl_auth -w '\n%{http_code}' -X POST -d "${robot_payload}" "${API}/robots")"
  robot_status="$(echo "${robot_response}" | tail -n1)"
  robot_body="$(echo "${robot_response}" | sed '$d')"
  # A 409 here (this exact robot already existing) is NOT fatal: it
  # just means our lookup above missed it. Fall back once more to the
  # ID scan, delete, and retry the create exactly once.
  if [ "${robot_status}" = "409" ]; then
    log "POST /robots got 409 (robot already exists) despite the lookup above finding nothing -- retrying via ID-scan + rotate."
    retry_id="$(find_robot_id_by_scan || true)"
    if [ -z "${retry_id}" ]; then
      log "FATAL: POST /robots returned 409 but no matching robot could be located by ID scan either: ${robot_body}"
      exit 1
    fi
    del_status="$(curl_auth -o /dev/null -w '%{http_code}' -X DELETE "${API}/robots/${retry_id}")"
    if [ "${del_status}" != "200" ] && [ "${del_status}" != "204" ]; then
      log "FATAL: DELETE /robots/${retry_id} (409-recovery) returned HTTP ${del_status}"
      exit 1
    fi
    log "deleted stale robot account (id=${retry_id}) found via ID scan; retrying create..."
    robot_response="$(curl_auth -w '\n%{http_code}' -X POST -d "${robot_payload}" "${API}/robots")"
    robot_status="$(echo "${robot_response}" | tail -n1)"
    robot_body="$(echo "${robot_response}" | sed '$d')"
  fi
  if [ "${robot_status}" != "201" ]; then
    log "FATAL: POST /robots returned HTTP ${robot_status}: ${robot_body}"
    exit 1
  fi

  new_id="$(echo "${robot_body}" | jq -r '.id')"
  new_secret="$(echo "${robot_body}" | jq -r '.secret // empty')"
  if [ -z "${new_secret}" ]; then
    log "FATAL: robot created (id=${new_id}) but the response had no .secret field -- cannot proceed without capturing it (this is the ONLY time Harbor reveals it)"
    exit 1
  fi
  log "created robot account '${ROBOT_FULL_NAME}' (id=${new_id}); writing its one-time secret to k8s Secret '${ROBOT_K8S_SECRET_NAME}' (ns ${K8S_NAMESPACE})..."
  write_k8s_secret "${ROBOT_FULL_NAME}" "${new_secret}"
  log "k8s Secret '${ROBOT_K8S_SECRET_NAME}' written."
fi

log "done. dockerhub-proxy (public) + dev (private) projects + ${ROBOT_FULL_NAME} robot are configured."
