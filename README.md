# onedata-gitops-landscapes

GitOps home for **full-stack, hermetic Onedata landscapes** on Kubernetes,
driven by [Argo CD](https://argo-cd.readthedocs.io/) and the
[`onedata-operator`](https://github.com/groundnuty/onedata-operator).

Realizes design `onedata-operator-design.md` it.176 (the GitOps-landscapes
model), building on it.5 ("the operator = reconciliation; GitOps = an
optional git-sync layer on top") and it.141/146 ("GitOps = the durable
source of truth" for re-derivable state + sealed secrets).

> **DEMO REPOSITORY -- NOT FOR PRODUCTION.**
> Every landscape in this repo ships **plaintext demo credentials**
> (admin/onepanel passwords, user attributes) committed directly to git,
> by deliberate maintainer decision (it.176) for scaffolding velocity.
> **Never put a real credential in this repo.** A real fork of this model
> would replace the `Secret` manifests under each landscape's `crs/` with
> [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) or an
> equivalent (SOPS, External Secrets Operator, ...) -- noted here, not
> built here.
>
> **The ONE exception to the plaintext convention: the deSEC API token**
> (it.185 real-TLS chain). It grants write access to a real DNS zone --
> which is certificate-issuance control -- so it NEVER goes in git, in
> any form. `make desec-token TOKEN=...` writes it straight to the
> cluster; see `platform/cert-manager-desec/README.md`'s "Token
> handling".

## The model

Each **landscape** is the WHOLE Onedata stack, hermetically self-contained
in its own Kubernetes namespace, expressed as one Argo CD `Application`
that syncs a directory of Kubernetes manifests ordered by
[sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/):

```
wave 0: cert-config      (Issuer/Certificate -- the it.165 self-signed test path)
wave 1: operator         (a namespace-scoped, VERSION-PINNED onedata-operator instance)
wave 2: CRs               (Onezone, Oneprovider, StorageBackend, Space, User, Support, ...)
```

(Wave 0 is a landscape-level convenience, not mandatory: `sv-posix-multinode/v2`
omits it entirely, driving TLS directly off each managed CR's own
`spec.tls` instead -- see that landscape's `kustomization.yaml` for why.)

**The operator version lives IN the landscape, in git, pinned per
landscape.** This is the whole point (it.176's "dissolves Hole 3"):
different landscapes can run different operator versions side by side,
with no cluster-wide-manager version fighting. Each landscape's operator
Deployment is a **namespace-scoped** instance (`--watch-namespace=<ns>`,
`Role`/`RoleBinding` instead of `ClusterRole`/`ClusterRoleBinding`)
confined to that one namespace.

### The one shared, cluster-scoped exception: CRDs

The 8 `onedata.org` + 1 `testing.onedata.org` CRDs are **cluster-scoped
singletons** -- there is exactly one copy cluster-wide, shared by every
landscape's per-namespace operator instance. They are **not** part of any
landscape's app-of-apps; they are a **separate, superset/latest
prerequisite** applied once (`make apply-crds`, see `crds/`). This
repo's additive-only CRD evolution (a rule the operator repo itself
follows) keeps one CRD set compatible across every landscape's pinned
operator version, old or new.

### Argo CD itself

Argo CD is installed **once per cluster**, in its own dedicated namespace
(`onedata-gitops-argocd`), with **cluster-wide RBAC** (it needs to manage
every landscape namespace) but **not publicly exposed** -- reach the UI
only via `make argocd-ui` (port-forward), never through an Ingress/
LoadBalancer. Basic/insecure auth is an accepted demo trade-off, not a
production posture.

**Argo CD is the one bootstrap exception to "everything is Argo-managed":**
it cannot GitOps-deploy itself before it exists. `make argocd-install`
applies its manifests directly via `kubectl`/`kustomize`, imperatively,
once. Every landscape and every platform app *after* that point is
Argo-managed.

## Directory layout

```
argocd/                       dedicated-namespace Argo CD install + health/ignoreDifferences config
crds/                          the ONE shared, cluster-scoped CRD set (superset/latest)
platform/cert-manager-desec/   deSEC DNS-01 webhook solver + Let's Encrypt ClusterIssuers (it.185 real TLS)
platform/onedata-dev-ca/       cluster-singleton shared dev CA ClusterIssuer (it.194-196/200/203)
platform/harbor/               cluster-singleton Harbor (proxy-cache + dev push target; it.178/179/183; LE TLS via it.185)
landscapes/<name>/<version>/   a full hermetic landscape's manifests, wave-annotated
applications/
  platform/                   cluster-SINGLETON Argo apps (one per cluster; see below)
  landscapes/                 one root Application per landscape VERSION (many; individually applied)
scripts/                      operational helpers that are NOT auto-run by any Makefile target
```

### `applications/platform/` vs `applications/landscapes/`

- **`applications/platform/`** -- apps that exist **once per cluster**,
  outside any single landscape's lifecycle. **`harbor.yaml`** (pointing
  at `platform/harbor/`) is the first occupant: a Docker Hub
  proxy-cache project (`dockerhub-proxy`) plus a private `dev` project
  that is the authorized push target for feature-branch operator
  images and maintainer-approved patched Onedata core images (it.183),
  deployed via Argo into its own dedicated namespace
  `onedata-gitops-harbor` -- an "ours/demo" registry, not an official
  Onedata cluster service. See `platform/harbor/README.md` for the full
  design writeup and `applications/platform/README.md` for the
  platform-vs-landscape split. **GATED like every landscape** -- schema-
  valid and dry-run-clean, not yet applied to k8s-one.
- **`applications/landscapes/`** -- one Application per
  `<landscape>-<version>` (e.g. `sv-posix-multinode-v1.yaml`). Many of
  these accumulate over time, one per landscape release. **Individually
  applied** (`make deploy-landscape NAME=... VERSION=...`) -- there is
  deliberately **no auto-discovery root Application** scanning this
  directory; every landscape deploy is an explicit, reviewed act.

## Quickstart

```sh
devbox shell            # or prefix every command below with `devbox run --`
make help                # see every target
```

### Mandatory deploy sequence

**This order is load-bearing, not a suggestion.** Skipping step 1 risks
a real outage: the existing k8s-one cluster-wide `v0.5.0` manager
currently watches ALL namespaces. If a new landscape's CRs land in a
namespace it can still see, that stale binary will try to reconcile
them -- and `v0.5.0` **silently drops post-v0.5.0 spec fields**
(`spec.managed.storageVolume`, its own PosixDataEphemeral guard, ...),
because it does not know they exist. Two managers (the stale cluster-wide
one and the landscape's own namespace-scoped one) would also race each
other over the same CRs. See `scripts/scope-cluster-manager.sh`.

```
1. make scope-cluster-manager   # FIRST, always -- restarts the EXISTING
                                 # k8s-one v0.5.0 manager with
                                 # --watch-namespace=landscape-max,demo-a
                                 # so it stops seeing (and corrupting)
                                 # new landscape namespaces. One-time
                                 # step per cluster, safe to re-run.
2. make apply-crds              # the superset/latest CRDs, once per cluster
3. make argocd-install           # Argo CD itself, once per cluster
4. make deploy-landscape NAME=sv-posix-multinode VERSION=v1
```

`make deploy-landscape` **will not run steps 1-3 for you** -- each is its
own explicit, auditable action. Running `deploy-landscape` before 1-3
land is a foot-gun this repo will not paper over.

**Re-run step 2 (`make apply-crds`) before deploying a landscape that
needs a CRD field newer than what is currently applied** -- e.g.
`sv-posix-multinode/v2` needs `spec.tls.trustIssuerCA`, added to
`crds/` alongside that landscape per the superset-bump rule in
`crds/README.md`. `apply-crds` is safe to re-run any number of times
(additive-only, idempotent) -- it is a "once per cluster **per CRD
bump**", not strictly "once ever".

> **This scaffold did not run any of the four steps above.** Building
> the repo's content (and validating it renders/schema-checks) is this
> task's scope; deploying to k8s-one is an explicit, separate, gated
> follow-up.

### Optional platform apps: cert-manager-desec + Harbor

Harbor (`platform/harbor/`, it.178/179/183) and its TLS chain
(`platform/cert-manager-desec/`, it.185 + the maintainer's deSEC
decision) are **independent of the four-step sequence above** -- they
don't gate any landscape, and no landscape gates them. They only need
Argo CD to already exist. **Within the Harbor chain, though, THIS
order is load-bearing** (Harbor's nginx pod blocks on the issued
`harbor-tls` Secret; the issuers block on the token):

```
make argocd-install                                        # step 3 above, if not already done
make set-harbor-domain DOMAIN=harbor.<name>.dedyn.io       # once, after the maintainer's deSEC account
                                                            #   exists; rewrites the CHANGEME placeholder
                                                            #   repo-wide -- review `git diff`, commit, push
                                                            #   (Argo syncs from git, not your working tree)
make desec-token TOKEN=<real-desec-token>                   # the ONE real credential -> cluster Secret, NEVER git
make dns-record HARBOR_NODE_IP=<node-InternalIP>            # idempotent deSEC A record (re-run to re-point)
make certmanager-desec-deploy                                # webhook solver + letsencrypt-{,staging-}dns01 issuers
make harbor-deploy                                           # Harbor itself, TLS'd with a REAL Let's Encrypt cert
make harbor-configure                                        # dockerhub-proxy + dev projects + push robot (idempotent)
```

**RECOMMENDED: staging-first on the first issuance** -- flip
`platform/harbor/certificate.yaml`'s issuerRef to
`letsencrypt-staging-dns01`, verify READY=True, flip back and delete
the staging Secret. Full procedure + rate-limit rationale in
`platform/cert-manager-desec/cluster-issuers.yaml`'s header. (dedyn.io
is on the Public Suffix List, so `<name>.dedyn.io` gets its OWN Let's
Encrypt rate-limit bucket -- but it's still finite.)

**Also not run by this build** -- content + dry-run validation only,
same gating as every landscape. See `platform/harbor/README.md` +
`platform/cert-manager-desec/README.md` for the full designs and
"Using the Harbor proxy-cache from a landscape" below for how a
landscape actually consumes Harbor once deployed.

### Optional platform app: onedata-dev-ca (it.194-196/200/203)

`platform/onedata-dev-ca/` -- a shared, cluster-singleton CA
`ClusterIssuer` every dev landscape's managed Onezone/Oneprovider CRs
can point their own `spec.tls.issuerRef` at (plus
`spec.tls.trustIssuerCA: true`) instead of always needing a public
Let's Encrypt name. **Independent of Harbor/cert-manager-desec and of
the four-step mandatory sequence** -- only needs Argo CD to already
exist:

```
make argocd-install   # if not already done
make dev-ca-deploy
```

See `platform/onedata-dev-ca/README.md` for the full design (why a
third CA-type `ClusterIssuer`, why it deploys into the pre-existing
`cert-manager` namespace, rotation caveats) and
`landscapes/sv-posix-multinode/v2/README.md` for the reference
landscape that consumes it. **GATED, same as every platform app in
this repo:** schema-valid and dry-run-clean, NOT yet applied to
k8s-one.

### Everyday targets

```sh
make argocd-login                          # fetch the initial admin password, argocd CLI login
make argocd-ui                             # port-forward the Argo CD UI (localhost only)
make list-landscapes                       # what's under landscapes/
make delete-landscape NAME=... VERSION=... # remove a landscape's root Application (and, per its syncPolicy, its resources)
make argocd-uninstall                      # tear down the Argo CD install
make validate                              # kustomize build + kubectl create --dry-run=client everywhere
make set-harbor-domain DOMAIN=...          # one-shot: rewrite the harbor.k8s-one-onedata.dedyn.io placeholder repo-wide
make desec-token TOKEN=...                 # the real deSEC token -> cluster Secret (NEVER git)
make dns-record HARBOR_NODE_IP=...         # idempotent deSEC A record for the Harbor name
make certmanager-desec-deploy              # apply the cert-manager-desec platform Application (gated)
make harbor-deploy                         # apply the Harbor platform Application (gated -- see "Optional platform apps")
make harbor-configure                      # (re-)run Harbor's config-as-code Job: dockerhub-proxy + dev projects + push robot
make harbor-ui                             # port-forward the Harbor UI (localhost only; expect the cert-SAN/localhost mismatch warning)
make harbor-login                          # docker login to Harbor's `dev` project from large-dev (robot account; real LE TLS, no insecure-registry config)
make harbor-push IMAGE=...                 # tag + push an image into Harbor's `dev` project
make harbor-pull-secret NS=...             # create the imagePullSecret for Harbor's `dev` project in namespace NS
make dev-ca-deploy                         # apply the onedata-dev-ca platform Application (gated; it.194-196/200/203)
```

## Landscapes

| Name | Version | What it proves | Operator image |
|---|---|---|---|
| [`sv-posix-multinode`](landscapes/sv-posix-multinode/v1/README.md) | `v1` | `spec.managed.storageVolume` on a real RWX `nfs-xattr` PVC + `workerNodes: 2` (it.161/164) -- the multi-worker shared-posix feature | `groundnuty/onedata-operator:v0.6.0` (**forward reference -- see landscape README**) |
| [`sv-posix-multinode`](landscapes/sv-posix-multinode/v2/README.md) | `v2` | SAME feature as v1, "productionized" (it.196/203): dev-CA TLS (`trustIssuerCA`) + Harbor images (operator from the `dev` project, Onedata components via `dockerhub-proxy`) + NetworkPolicy-default-off. Deploys ALONGSIDE v1, own namespace | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onedata-operator:v0.6.1` (**forward reference -- see landscape README**) |

## Harbor: proxy-cache + dev push target (it.178/179/183; real LE TLS via it.185; DEFAULT image path since it.203)

`platform/harbor/` (Argo Application: `applications/platform/harbor.yaml`)
is a cluster-singleton, GATED like every landscape -- see
`platform/harbor/README.md` for the full design (chart-vendoring
choice, the TLS-v2 exposure story, resource sizing, config-as-code
robot model) and `platform/cert-manager-desec/README.md` for the
Let's Encrypt DNS-01 issuance chain behind it. This section covers the
two things a *landscape* author needs to know to actually use it.

> **Wildcard note (mentioned, not built):** the same
> `letsencrypt-dns01` issuer can mint a `*.<name>.dedyn.io` wildcard
> (DNS-01 is the only ACME challenge type that can) -- one future cert
> covering the Argo CD UI and any other platform app. Argo CD stays
> port-forward-only by design today.

### Using the proxy-cache from a landscape: the image-prefix overlay pattern

Harbor's `dockerhub-proxy` project (public, no auth needed to pull)
mirrors any Docker Hub image the first time it's requested, then serves
every subsequent pull from LAN speed. A landscape opts in with a
**kustomize overlay**, not by editing its own base manifests --
`images:` is kustomize's built-in transformer for exactly this, and it
targets the standard `spec.containers[].image` field of any
Pod-template-bearing kind (Deployment/StatefulSet/Job/...). Example,
rewriting a landscape's own namespace-scoped operator image:

```yaml
# landscapes/<name>/<version>/overlays/harbor-proxy/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../.. # the base landscape, unmodified
images:
  - name: groundnuty/onedata-operator
    newName: harbor.k8s-one-onedata.dedyn.io:30003/dockerhub-proxy/groundnuty/onedata-operator
    # newTag: left unset -- keeps whatever tag the base kustomization pinned
    # (the CHANGEME placeholder is rewritten repo-wide by `make
    # set-harbor-domain`; the name resolves via the deSEC A record and
    # the NodePort is reachable on all 22 nodes)
```

Then `kustomize build .../overlays/harbor-proxy/` instead of the base
directory directly.

**The v1 known gap here is DISSOLVED (it.185):** this used to carry a
warning that any node a rewritten-image pod schedules onto needed its
own k3s containerd taught to trust Harbor's plaintext HTTP endpoint --
a real, unautomated, 22-node operational step. With TLS-v2 (a genuine
Let's Encrypt certificate on `harbor.<name>.dedyn.io:30003` -- see
`platform/harbor/README.md`'s "Exposure and TLS (v2)" and
`platform/cert-manager-desec/`), every node's containerd trusts the
endpoint natively via the stock CA bundle. No per-node trust config,
no `insecure-registries`, nothing to automate -- the reason the gap
existed is gone. (The deleted large-dev-side workaround lives in git
history, commit `a76bc97`, should plaintext ever need resurrecting.)

Separately, this pattern covers plain `spec.containers[].image`
fields. It does **not** reach an `onedata.org` CR's own image spec
field -- `Oneprovider.spec.managed.image`/`Onezone.spec.managed.image`
(these already exist, and are what a managed CR uses to select its own
Onezone/Oneprovider component image) are custom CRD schema fields, not
the standard PodSpec path kustomize's `images:` transformer understands
structurally. Rewriting those via the overlay pattern above would need
a `replacements:`/JSON6902 patch targeting the specific field path
instead.

**`sv-posix-multinode/v2` is the first landscape to actually reference
a Harbor path on one of these CR image fields** (design it.203) --
`crs/onezone.yaml`/`crs/oneprovider.yaml` set
`spec.managed.image: harbor.k8s-one-onedata.dedyn.io:30003/dockerhub-proxy/onedata/{onezone,oneprovider}:21.02.7`
directly as a **literal value in the base manifest**, not through a
kustomize overlay -- simpler than a JSON6902 patch when a landscape
commits to Harbor from the start (as v2 does) rather than layering it
on top of an existing public-ref base (as the operator-image overlay
example above does for a *hypothetical* landscape that wants both
options). The `replacements:`/JSON6902-overlay gap noted above still
applies to any landscape that wants to keep a portable base *and*
optionally rewrite a CR's own image field via overlay -- not needed by
v2, which commits to the Harbor ref outright.

### The it.183 exception: patched/experimental images are NOT portable

The it.178 baseline rule for every git-committed landscape: image refs
stay **public and durable** (`groundnuty/...`, `onedata/...`) --
Harbor is a transparent accelerator/dev-push-target, never the
canonical home an actual landscape manifest depends on to be
reproducible on a fresh cluster.

**it.183 carves out one maintainer-authorized exception:** this
cluster's own Harbor `dev` project may be referenced directly by an
experimental/patched landscape (e.g. one running a
`DYNAMIC_MEMBERSHIP`-patched core image, which is local-only and can
never be pushed publicly or to any Onedata registry). Any landscape
that does this **must** mark the reference loudly, inline, at the
point of use:

```yaml
# EXPERIMENTAL / PATCHED CORE -- NOT PUBLICLY AVAILABLE.
# Lives ONLY in this cluster's own Harbor `dev` project (it.183's
# maintainer-authorized exception). NOT groundnuty/onedata-operator or
# any onedata/* image; unpullable on any other cluster. See
# platform/harbor/README.md's "it.183" section.
image: harbor.k8s-one-onedata.dedyn.io:30003/dev/op-worker:dynamic-membership-abc1234
```

(The public dedyn.io name, not the `*.svc.cluster.local` Service DNS
name: the Let's Encrypt cert's SAN covers only the public name, so
since TLS-v2 the Service name is not a valid registry endpoint for
containerd -- see `platform/harbor/README.md`'s "Exposure and TLS
(v2)".)

This was, at the time it.183 was written, the **only** documented
exception to the public-refs principle. **it.203 adds a second, of a
different character** -- see immediately below.

### it.203: Harbor promoted from "available exception" to DEFAULT image path

The it.178 baseline above (public/durable refs; Harbor as accelerator,
never the canonical home) was the right call while Harbor was new and
unproven. Once it.198's first live deploy proved Harbor's TLS chain and
config-as-code end to end, the maintainer's it.203 directive promoted
Harbor to the **default image path for every landscape going forward**:
operator images push to the `dev` project, Onedata component images
route through `dockerhub-proxy`. `sv-posix-multinode/v2` is the
reference implementation (see its own README's image-pin table).

**This is NOT the same as the it.183 exception**, even though both
reference the `dev` project, and it is worth being precise about the
difference:

- **it.183** authorizes referencing the `dev` project for an image that
  has **no public equivalent at all** (a locally patched core build) --
  the landscape referencing it is *structurally* non-portable; there is
  no fallback ref to fall back to.
- **it.203 / v2's operator image** (`harbor.k8s-one-onedata.dedyn.io:30003/dev/onedata-operator:v0.6.1`)
  is an **unmodified, otherwise-public release** -- the SAME bits are
  also pushed to Docker Hub as `groundnuty/onedata-operator:v0.6.1` per
  it.203's own directive. v2 pins the Harbor ref by **policy choice**
  (this cluster's own hardware, per the maintainer's directive), not
  because a public equivalent doesn't exist. A cluster without this
  Harbor could substitute the Docker Hub ref for the identical bits --
  v2 itself does not, by design.
- **v2's Onedata *component* images** (`dockerhub-proxy/onedata/{onezone,oneprovider}:21.02.7`)
  are a third, more benign case still: `dockerhub-proxy` is a
  **proxy-cache of an already-public image**, not a push target at all
  -- the portable fallback is simply dropping the `dockerhub-proxy/`
  prefix and pulling `onedata/{onezone,oneprovider}:21.02.7` straight
  from Docker Hub. No exception, no non-portability -- purely an
  accelerator, exactly what `dockerhub-proxy` was designed for.

**Practical upshot for future landscape authors:** default to the
Harbor-prefixed refs (operator image from `dev`, component images via
`dockerhub-proxy`, `make harbor-pull-secret NS=...` for whichever
namespace needs the private pull) unless there's a specific reason not
to (e.g. a landscape meant to be reproduced on a cluster with no
Harbor of its own).

### The pull-secret pattern: `make harbor-pull-secret`

The `dev` project is private -- a landscape's namespace-scoped operator
(or any pod) pulling FROM it (as opposed to large-dev pushing TO it)
needs an `imagePullSecret`:

```sh
make harbor-pull-secret NS=<landscape-namespace>
```

creates a `kubernetes.io/dockerconfigjson` Secret named
`harbor-dev-pull` in `NS`, built from the same `harbor-dev-robot`
credential `platform/harbor/secrets.yaml` already defines (robot
accounts can both push and pull within their scoped project -- see
`platform/harbor/README.md`'s "Robot account and auth model"). Since
TLS-v2 the secret's `docker-server` is the PUBLIC name
(`harbor.<name>.dedyn.io:30003` -- the LE cert's SAN, which containerd
verifies), not the in-cluster Service DNS name. A landscape references
it the normal Kubernetes way, on whichever ServiceAccount/Pod spec
pulls the image:

```yaml
# e.g. landscapes/<name>/<version>/operator/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: <name>-operator
  namespace: <landscape-namespace>
imagePullSecrets:
  - name: harbor-dev-pull
```

or directly on a Pod spec via `spec.imagePullSecrets`. First wired up
by `sv-posix-multinode/v2` (`operator/serviceaccount.yaml`) -- its
operator image comes from the `dev` project (it.203), so it needs
exactly this: `make harbor-pull-secret NS=sv-posix-multinode-v2` before
that landscape's operator pod can pull. (`v1`, still pinning the public
`groundnuty/onedata-operator:v0.6.0` ref, needs none of this.)

## Argo CD config notes (see `argocd/README.md` for the full writeup)

- **No server-side-apply in the operator** (verified by source inspection
  -- no `client.Apply`/`types.ApplyPatchType`/`FieldOwner` usage anywhere
  in `internal/controller/`; every mutation is a plain typed
  `Update`/`Status().Update`, and the *only* fields any reconciler ever
  writes back onto a CR's `spec` are `metadata.finalizers` via
  `controllerutil.{Add,Remove}Finalizer`). So `ignoreDifferences` uses
  the **JSON-pointer (`jsonPointers`) form**, not `managedFieldsManagers`
  -- there are no competing field managers to reconcile against, only two
  concrete, confirmed always-out-of-sync paths per kind: `/status` and
  `/metadata/finalizers`.
- **CRD `additionalPrinterColumns` already exist** on every primitive CRD
  (including a `Phase` column reading `.status.phase`) -- that half of
  it.176's health-UX ask was already done upstream, nothing to add here.
  This repo adds the other half: a ~10-line Argo Lua health check per
  kind, reading the same `status.phase`, so a landscape's Argo
  `Application` tile goes green exactly when the whole CR graph does.

## Known gaps (documented, not hidden -- it.100/104 discipline)

- **`StorageBackend.spec.onepanelEndpoint` / `User.spec.onepanelEndpoint`
  are drive-first fields, not GitOps-static.** Both are the managed
  Oneprovider/Onezone's onepanel **pod IP** (confirmed by source read of
  `internal/controller/oneprovider_managed.go`'s
  `refreshManagedEndpoint` -- deliberately pod-IP-based, not
  Service-DNS-based, because a round-robin Service does not reliably
  reach the one bootstrapped onepanel instance), which does not exist
  until the Oneprovider/Onezone reaches `Ready`. **Identical, already-
  accepted limitation** to `demo/landscape-3p` and `demo/landscape-max`
  in the operator repo. This repo follows the same precedent: those two
  CRs' `onepanelEndpoint` ship empty in the wave-2 static manifests, and
  a small companion script
  (`landscapes/<name>/<version>/apply-dependent-crs.sh`) applies the
  endpoint-dependent CRs (`StorageBackend`, `User`, then `Space`,
  `Support`) as a **documented manual day-2 step** after the Argo sync
  reaches wave 2 and the Oneprovider/Onezone go `Ready`. A cleaner
  Argo-native fix (an Argo `PostSync` hook `Job` running this same
  script) is a good follow-up, flagged here, not built in this scaffold.
- **RBAC: `PersistentVolume` is cluster-scoped; a namespaced
  `Role`/`RoleBinding` structurally cannot grant access to it**, no
  matter what the `Role`'s rules say -- Kubernetes RBAC only ever
  authorizes cluster-scoped resources via a `ClusterRole` bound with a
  `ClusterRoleBinding`. The upstream `manager-role` `ClusterRole`
  includes a `persistentvolumes` rule (needed by
  `TestStorageFixtureReconciler` for `dataImage`-seeded fixtures, whose
  `Reconcile` creates PVs directly -- confirmed by source read; no
  controller registers a *permanent cache watch* on `PersistentVolume`,
  so this is a reactive-only gap, not a manager-startup blocker). Every
  landscape's namespaced `operator/role.yaml` here **drops
  `persistentvolumes`** -- safe as long as that landscape's own CR set
  never includes a `TestStorageFixture` with `dataImage` seeding. If one
  ever needs that, its operator RBAC must become a `ClusterRole` +
  `ClusterRoleBinding`, which breaks this repo's namespace-isolation
  model -- flagged, not solved, here.
