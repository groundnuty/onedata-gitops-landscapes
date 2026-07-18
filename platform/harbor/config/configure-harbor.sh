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
# All four are look-before-you-create: re-running this script against
# an already-configured Harbor is a no-op (logged, not skipped
# silently) for every step.
set -euo pipefail

HARBOR_URL="${HARBOR_URL:-http://harbor-core.onedata-gitops-harbor.svc.cluster.local}"
HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:?set from the harbor-admin-secret Secret (HARBOR_ADMIN_PASSWORD key)}"
DOCKERHUB_REGISTRY_NAME="${DOCKERHUB_REGISTRY_NAME:-dockerhub}"
PROXY_PROJECT_NAME="${PROXY_PROJECT_NAME:-dockerhub-proxy}"
DEV_PROJECT_NAME="${DEV_PROJECT_NAME:-dev}"
ROBOT_SHORT_NAME="${ROBOT_SHORT_NAME:-large-dev-push}"
ROBOT_SECRET="${ROBOT_SECRET:?set from the harbor-dev-robot Secret (password key) -- RobotCreate.secret accepts a caller-supplied value, so this is the SAME plaintext demo string make harbor-login/harbor-pull-secret read back, not something generated and captured}"
ROBOT_FULL_NAME="robot\$${DEV_PROJECT_NAME}+${ROBOT_SHORT_NAME}"

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
if [ "$(curl_auth "${API}/projects?name=${DEV_PROJECT_NAME}" | jq -r 'length')" -gt 0 ]; then
  log "project '${DEV_PROJECT_NAME}' already exists"
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
log "checking for robot account '${ROBOT_FULL_NAME}'..."
robot_exists="$(curl_auth -G --data-urlencode "q=name=${ROBOT_FULL_NAME}" "${API}/robots" | jq -r 'length')"
if [ "${robot_exists}" -gt 0 ]; then
  log "robot account '${ROBOT_FULL_NAME}' already exists -- leaving its secret untouched (Harbor never re-shows a robot's secret; if it must change, delete the robot AND rotate harbor-dev-robot's Secret value together, then re-run this script)"
else
  robot_payload="$(jq -n \
    --arg name "${ROBOT_SHORT_NAME}" \
    --arg secret "${ROBOT_SECRET}" \
    --arg ns "${DEV_PROJECT_NAME}" \
    '{
      name: $name,
      description: "push/pull from large-dev docker for feature-branch + patched-core images (it.183)",
      secret: $secret,
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
  robot_response="$(curl_auth -w '\n%{http_code}' -X POST -d "${robot_payload}" "${API}/robots")"
  robot_status="$(echo "${robot_response}" | tail -n1)"
  robot_body="$(echo "${robot_response}" | sed '$d')"
  if [ "${robot_status}" != "201" ]; then
    log "FATAL: POST /robots returned HTTP ${robot_status}: ${robot_body}"
    exit 1
  fi
  log "created robot account '${ROBOT_FULL_NAME}' (id=$(echo "${robot_body}" | jq -r '.id'))"
fi

log "done. dockerhub-proxy (public) + dev (private) projects + ${ROBOT_FULL_NAME} robot are configured."
