# Harbor -- cluster-singleton platform app

Realizes design it.178 (approved), it.179 (Argo-managed platform-app
refinement), it.183 (the push-target authorization + public-refs
exception), and it.185 TLS-v2 (real Let's Encrypt via deSEC DNS-01 --
see "Exposure and TLS (v2)" below and
`platform/cert-manager-desec/README.md` for the issuer side). See
`applications/platform/README.md` for the
platform-vs-landscape distinction; this directory is the CONTENT half
of that split (`applications/platform/harbor.yaml` is the thin Argo
`Application` pointer into it).

Two jobs, one Harbor instance:

1. **A `dockerhub-proxy` project** -- a Docker Hub proxy-cache. 22 k8s-one
   nodes independently pulling the same 1-2GB Onedata images, across
   many landscape versions, means one external pull per image, then
   LAN speed for the other 21 nodes, and no more Docker Hub anonymous
   rate-limit exposure.
2. **A private `dev` project** -- the push target for feature-branch
   `onedata-operator` images AND maintainer-authorized patched Onedata
   core images (it.183). Never a public push, never an Onedata-registry
   push (`docker.onedata.org*`/`onedata/*` stay deny-listed, unchanged)
   -- see "it.183: the push-target exception" below.

## helm-vendored vs. Argo Helm source

**Chosen: vendor the rendered manifests** (`vendor/harbor-1.18.4-rendered.yaml`),
same as `argocd/vendor/install-v3.4.4.yaml` -- Argo CD itself never
talks to `helm.goharbor.io`; only whoever re-renders this file locally
does (see the vendored file's own header comment for the exact
regeneration command).

Why, over an Argo `spec.source.helm` pointing at the upstream chart
repo directly:

- **Consistency with this repo's only other precedent.** `argocd/`
  already made this call, for the same reason: a `kubectl
  apply`/`kustomize build`-equivalent Argo sync never needs live
  network access to a third-party chart registry at sync time. A
  landscape's whole premise is "hermetic" (see the top-level README);
  a platform app pulling `helm.goharbor.io` on every sync/refresh cuts
  against that, however slightly.
- **Auditability.** `git diff` on a vendored, fully-rendered manifest
  shows you exactly what changes, in plain Kubernetes YAML, the same
  way it does for every landscape's static CRs. An Argo Helm source's
  diff is a `values.yaml` diff -- correct but one level removed from
  what actually lands on the cluster.
- **No extra moving part in the sync path.** Argo's native Helm
  support is fine, but it means Argo's own repo-server needs outbound
  network + chart-repo availability as a dependency of every sync,
  compaction, and refresh. Vendoring removes that dependency entirely
  for anyone just running `make harbor-deploy`.

The trade-off, stated plainly: upgrading the chart version is a manual
re-render + `git diff` review, not a one-line `targetRevision` bump.
Given Harbor upgrades are infrequent and this is a demo/dev-support
platform app (not itself part of the acceptance surface), that trade
favors vendoring here, same as it did for Argo CD's own install.

**Chart version pinned: `1.18.4`** (Harbor app version `2.14.4`) --
the newest `.4`-patch release available in the `harbor/harbor` repo at
build time (`1.19.x` existed but was a fresher `.0`/`.1` minor with
less patch-soak; `1.18.4` was chosen for the same "not `latest`, not
bleeding-edge-unpatched" reasoning as `argocd/`'s `v3.4.4` pin).

## Exposure and TLS (v2: real Let's Encrypt via deSEC DNS-01 -- it.185)

**Chosen: in-cluster Service + NodePort, `expose.tls.enabled: true`,
`certSource: secret` pointed at the cert-manager-issued `harbor-tls`
Secret** (`certificate.yaml`, issued by
`platform/cert-manager-desec/`'s `letsencrypt-dns01` ClusterIssuer).
Fixed NodePorts: `30003` https (the registry endpoint clients use),
`30002` http (still rendered by the chart, but nginx now 301-redirects
it to the https externalURL -- a redirect, not a service endpoint).
`externalURL: https://harbor.<name>.dedyn.io:30003` -- with
`expose.type: nodePort` + TLS the chart expects exactly this
`https://<cert-SAN>:<https-nodePort>` shape (externalURL feeds both
the UI's docker-command hints and the token-service URL Harbor returns
to docker clients, so a mismatch breaks `docker login` even when
routing works).

Why this is the v1 "quick option"'s clean successor, not more moving
parts for their own sake:

- **The trust problem is REMOVED, not configured around.** v1's whole
  HTTP-internal rationale was that a self-signed cert and plaintext
  cost the same client-side surgery (`--insecure-registry` /
  per-node containerd trust). A genuine Let's Encrypt chain costs
  NEITHER: ISRG roots ship in every stock CA bundle, so all 22 nodes'
  k3s containerd and large-dev's docker daemon trust
  `harbor.<name>.dedyn.io:30003` natively. The
  `harbor-configure-insecure-registry` target and its script are
  DELETED (git history, commit `a76bc97`, if plaintext must ever be
  resurrected).
- **Still no internet exposure.** DNS-01 proves domain control via a
  TXT record on deSEC's public nameservers -- Let's Encrypt never
  connects to the cluster (that would be HTTP-01). The A record
  (`make dns-record`) publishes a PRIVATE node IP (10.87.x) under the
  public name: resolvable everywhere, reachable only from the
  LAN/VPN. Not a LoadBalancer, not an Ingress, no public IP --
  unchanged from v1.
- **The name, not an IP, is now the endpoint.** `make set-harbor-domain
  DOMAIN=harbor.<name>.dedyn.io` rewrites the committed
  `harbor.CHANGEME.dedyn.io` placeholder repo-wide (values.yaml,
  certificate.yaml, the vendored render's baked `EXT_ENDPOINT`, the
  Makefile default) in one reviewed commit. Certificates are issued to
  names; hardcoded node IPs stop appearing in client configuration
  entirely.
- **Bootstrapping order is load-bearing:** nginx's pod mounts the
  `harbor-tls` Secret, so Harbor's front door does not start until
  cert-manager has issued it. Hence the documented sequence:
  `desec-token` -> `dns-record` -> `certmanager-desec-deploy` ->
  `harbor-deploy`. **Staging-first on first issuance** -- see
  `certificate.yaml`'s header and
  `platform/cert-manager-desec/cluster-issuers.yaml` for the exact
  flip-verify-flip-back procedure that avoids burning prod rate
  limits.
- **Fallback if TLS bootstrapping fails** (issuer stuck, DNS broken,
  deSEC outage): the HTTP-internal v1 profile is one `git revert` away
  -- `expose.tls.enabled: false`, drop `certificate.yaml`, re-render,
  and re-apply the insecure-registry workaround from history. Kept as
  a documented escape hatch, deliberately NOT as a maintained parallel
  profile (two exposure modes = double the drift surface).

In-cluster consumers use the SAME public name
(`harbor.<name>.dedyn.io:30003`): the LE cert's SAN cannot cover
`*.svc.cluster.local`, so the Service DNS name is no longer a docker
endpoint (it remains fine for plain HTTP API automation -- the config
Job now targets `harbor-core`'s own Service directly for exactly this
reason). Pods resolve the dedyn.io name through CoreDNS's upstream
forwarding and reach the NodePort on any node.

## Storage: `csi-cinder-sc-retain`

Every PVC the chart creates (`registry` 20Gi, `jobservice.jobLog` 1Gi,
`database` 2Gi, `redis` 1Gi) is pinned to `csi-cinder-sc-retain`
(`persistence.resourcePolicy: keep` too) -- it.178's "cache survives
reinstalls": a `helm uninstall`/Argo-prune-and-redeploy cycle does not
lose the proxy-cache's already-pulled layers or the `dev` project's
already-pushed images, matching every other Retain-policy PVC decision
already made for this repo's stateful components.

## Resources modest (it.178: "~7 pods + PG + Redis, capacity trivial")

`trivy.enabled: false` (scanning is out of scope for a pull-accelerator
and dev-push registry; the biggest single resource cut, 512Mi-1Gi)
and `metrics.enabled: false` (no Prometheus in this cluster yet) trim
the pod count to the chart's baseline for `expose.type: nodePort`:
`nginx` (Harbor's own front-door router substituting for a real Ingress
controller when `expose.type != ingress`), `core`, `jobservice`,
`portal`, `registry` (2 containers: `registry` + `registryctl`) as
Deployments, plus `database` (internal Postgres) and `redis` as
StatefulSets -- 7 pods total. Every component's `resources.requests`/
`limits` are set to small, explicit values in `values.yaml` (no
component left at the chart's commented-out, effectively-unbounded
default).

## Config-as-code (it.179) -- what gets created and how

`config/configure-harbor.sh` (mounted into `config/job.yaml`, a
`batch/v1` Job at Argo sync-wave 1, run once Harbor's own wave-0
resources report Healthy) calls Harbor's REST API v2.0 to idempotently
ensure:

1. **A Registry endpoint** named `dockerhub`, `type: docker-hub`,
   anonymous (no credential).
2. **The `dockerhub-proxy` project**, `metadata.public: "true"`
   (frictionless pulls from any of the 22 nodes, no per-node Harbor
   login) with `registry_id` pointed at (1) -- this is what makes it a
   proxy-cache project, not a plain empty one.
3. **The `dev` project**, `metadata.public: "false"` -- the push
   target.
4. **A project-scoped Robot account**, `robot$dev+large-dev-push`,
   `level: project`, `duration: -1` (never expires), permissions
   `push`+`pull` on repositories, `read` on artifacts, `create` on tags
   -- scoped to `dev` ONLY. Least privilege: large-dev's docker daemon
   never needs the Harbor admin password for day-to-day pushes.

Every step is look-before-you-create (`GET` then conditionally `POST`)
-- safe to re-run. This matters because a Kubernetes `Job`'s
`spec.template` is immutable post-creation: **`make harbor-configure`
is the supported way to re-run this** (it deletes the existing Job
object first, then re-applies the whole `platform/harbor/`
kustomization, so a fresh Pod picks up whatever the mounted script
currently says). A bare Argo re-sync of an unchanged Job is a harmless
no-op; a bare re-sync after editing `configure-harbor.sh` will fail
with "field is immutable" -- by design, so the mismatch surfaces
immediately rather than silently mounting stale content.

### Docker Hub registry URL: a documented discrepancy from the original brief

This build was briefed to point the registry endpoint at
`https://registry-1.docker.io`. Source inspection of
`goharbor/harbor`'s `src/pkg/reg/adapter/dockerhub/{consts.go,adapter.go}`
found:

- `consts.go`: `baseURL = "https://hub.docker.com"` (the DockerHub
  adapter's namespace/tag-listing REST API host) and, separately,
  `registryURL = "https://registry-1.docker.io"` (a **hardcoded
  constant**, not read from the configured `Registry.url` field at
  all).
- `adapter.go`'s `newAdapter()` builds its inner pull-path
  (`native.Adapter`) pointed at that hardcoded `registryURL` constant
  **regardless of what URL you configure**. The registry's own
  `EndpointPattern` (what Harbor's UI offers as the only selectable
  value for `type: docker-hub`) is fixed to `https://hub.docker.com`.
- Server-side validation (`src/controller/registry/controller.go`'s
  `Create`) only calls a generic `lib.ValidateHTTPURL` -- it does not
  check the submitted URL against the adapter's `EndpointPattern`, so
  either URL would technically be *accepted*.

`configure-harbor.sh` sets `url: "https://hub.docker.com"` -- matching
Harbor's own documented/UI convention for this field -- with a comment
at the call site explaining this exact discrepancy. **No functional
difference either way**: actual proxy-cache image pulls always
traverse the hardcoded `registry-1.docker.io` path irrespective of
this field's value. Flagged here per this repo's "surface disagreements,
don't silently correct" discipline, not silently changed without
explanation.

## Robot account and auth model

`platform/harbor/secrets.yaml` (same plaintext-demo-creds-with-loud-warning
convention as every landscape's `crs/secrets.yaml`) holds:

- `harbor-admin-secret` -- Harbor's own `admin` superuser password,
  wired in via the chart's `existingSecretAdminPassword` (not the
  chart's own inline default).
- `harbor-dev-robot` -- `username: robot$dev+large-dev-push`,
  `password: demo-harbor-dev-robot-secret`.

The robot's password is **not** captured off a live API response after
the fact -- Harbor's `RobotCreate` API accepts a caller-supplied
`secret` field directly (verified against the v2.0 swagger's
`RobotCreate` schema), so `configure-harbor.sh` passes this exact,
pre-committed demo string as the robot's secret at creation time. That
is what makes it possible for this to be a plain, static, git-committed
demo value in the first place, exactly like every other credential in
this repo, rather than something generated once and then needing to be
stashed somewhere after the fact.

**If the robot secret ever needs to rotate:** delete the robot account
via the Harbor API/UI AND change `harbor-dev-robot`'s `password` value
in the same commit, then re-run `make harbor-configure` -- the script
will see no existing robot with that name and create a fresh one with
the new secret. Changing only the Secret without deleting the live
robot leaves the old secret still valid on the Harbor side (documented
in the script's own log line for this exact case).

## it.183: the push-target authorization + public-refs exception

The it.176/178 baseline rule for every **git-committed landscape**:
image refs stay **public and durable** (`groundnuty/...`, `onedata/...`)
-- Harbor is a transparent accelerator and a dev/push target, **never**
the canonical home for an image a landscape's manifest references.
An in-cluster registry is not portable; a public repo's landscapes
must stay portable.

**it.183 adds a maintainer-authorized, explicitly-marked exception**:
the isolation rule was never "patched images can't leave large-dev" --
it is (1) never push to an Onedata registry (`docker.onedata.org*`,
`onedata/*` -- deny-listed, unchanged), (2) never publish patched core
publicly (nothing mistakable for official Onedata -- unchanged), and
(3) **this Harbor, on our own cluster, counts as "local" in the
extended sense** -- an authorized push target for anything, including
`DYNAMIC_MEMBERSHIP`-patched core images (it.182's `growMode: Live`
capability, otherwise stuck local-only with no cluster to run on).

**Consequence for a landscape that uses this exception:** it is
legitimately non-portable, and must say so loudly. A landscape
referencing a `harbor.<name>.dedyn.io:30003/dev/...` image (the
public name -- the LE cert's SAN; the `*.svc.cluster.local` Service
name stopped being a valid registry endpoint with TLS-v2) needs a
comment at the reference site reading something like:

```yaml
# EXPERIMENTAL / PATCHED CORE -- NOT PUBLICLY AVAILABLE.
# This image lives ONLY in this cluster's own Harbor `dev` project
# (it.183's maintainer-authorized exception). It is NOT
# groundnuty/onedata-operator or any onedata/* image, and pulling this
# manifest on any other cluster without its own equivalent Harbor will
# fail. See platform/harbor/README.md's "it.183" section.
image: harbor.CHANGEME.dedyn.io:30003/dev/op-worker:dynamic-membership-abc1234
```

This is the ONLY documented exception to the it.178 public-refs
principle -- every other landscape in this repo keeps public, durable
refs (see the top-level README's Landscapes table).

## Using the proxy-cache from a landscape

See the top-level `README.md`'s "Using the Harbor proxy-cache from a
landscape" section for the kustomize image-prefix overlay pattern and
the pull-secret Makefile target (`make harbor-pull-secret NS=...`).

## Known gaps (documented, not hidden)

- **The v1 containerd-trust gap is DISSOLVED, not worked around**
  (it.185): the two v1 entries that used to lead this list -- "no
  cert-manager TLS" and "the 22 nodes' containerd don't trust Harbor's
  HTTP endpoint" -- are gone because their common cause (a plaintext/
  untrusted endpoint) is gone. With a genuine Let's Encrypt cert on
  `harbor.<name>.dedyn.io:30003`, every node's containerd and
  large-dev's docker trust the endpoint out of the box; there is no
  per-node `registries.yaml` surgery and no `insecure-registries`
  daemon.json entry anywhere. The old large-dev-side workaround
  (`make harbor-configure-insecure-registry` +
  `scripts/configure-docker-insecure-registry.sh`) is deleted -- git
  history (commit `a76bc97`) has it if plaintext HTTP must ever be
  resurrected.
- **What TLS-v2 newly depends on, honestly:** (1) the deSEC A record
  points at ONE node's IP -- lose that node and the NAME goes dark
  until `make dns-record HARBOR_NODE_IP=<other-node>` re-points it
  (TTL 3600 bounds the stale window); (2) in-cluster pulls resolve a
  public name via CoreDNS upstream forwarding -- a DNS-rebind-filtering
  resolver would break RFC1918 answers from public zones (k8s-one's
  default CoreDNS does not filter, noted in
  `platform/cert-manager-desec/README.md`); (3) cert renewal is
  cert-manager's job (renewBefore 30d) -- if renewal breaks, docker
  clients hard-fail at expiry, which is TLS working as designed, and
  the staging-first + `kubectl get certificate -A` check in the deploy
  docs is the observability hook.
- **`vendor/harbor-1.18.4-rendered.yaml`'s chart-internal secrets are
  non-reproducible across a re-render** -- see that file's own header
  comment; harmless, documented, not the same category as the
  deliberately-pinned demo creds in `secrets.yaml`.
- **The `dev` project has no image retention/GC policy configured** --
  a feature-branch/patched-core push target will accumulate images
  indefinitely against the `csi-cinder-sc-retain` PVC's fixed 20Gi.
  Harbor's own Tag Retention + GC features exist and are reachable
  through the same config-as-code Job pattern; not built in this v1,
  flagged as a natural follow-up once the `dev` project sees real
  traffic and its actual growth rate is known.
- **No image vulnerability scanning** (`trivy.enabled: false`) -- a
  deliberate v1 resource trade-off (see "Resources modest" above), not
  an oversight; revisit if this Harbor ever becomes more than a
  pull-accelerator/dev-push target.
