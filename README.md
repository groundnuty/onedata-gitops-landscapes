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
landscapes/<name>/<version>/   a full hermetic landscape's manifests, wave-annotated
applications/
  platform/                   cluster-SINGLETON Argo apps (one per cluster; see below)
  landscapes/                 one root Application per landscape VERSION (many; individually applied)
scripts/                      operational helpers that are NOT auto-run by any Makefile target
```

### `applications/platform/` vs `applications/landscapes/`

- **`applications/platform/`** -- apps that exist **once per cluster**,
  outside any single landscape's lifecycle. Today this directory is a
  placeholder (see `applications/platform/README.md`): the first planned
  occupant is **Harbor** (a private OCI registry for this repo's own
  images, deployed via Argo into its own dedicated namespace
  `onedata-gitops-harbor` -- an "ours/demo" registry, not an official
  Onedata cluster service). **Not built in this scaffold** -- a follow-up
  commit lands `platform/harbor/` + `applications/platform/harbor.yaml`
  once someone actually needs it.
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

> **This scaffold did not run any of the four steps above.** Building
> the repo's content (and validating it renders/schema-checks) is this
> task's scope; deploying to k8s-one is an explicit, separate, gated
> follow-up.

### Everyday targets

```sh
make argocd-login                          # fetch the initial admin password, argocd CLI login
make argocd-ui                             # port-forward the Argo CD UI (localhost only)
make list-landscapes                       # what's under landscapes/
make delete-landscape NAME=... VERSION=... # remove a landscape's root Application (and, per its syncPolicy, its resources)
make argocd-uninstall                      # tear down the Argo CD install
make validate                              # kustomize build + helm template + kubectl apply --dry-run=client everywhere, NO cluster contact
```

## Landscapes

| Name | Version | What it proves | Operator image |
|---|---|---|---|
| [`sv-posix-multinode`](landscapes/sv-posix-multinode/v1/README.md) | `v1` | `spec.managed.storageVolume` on a real RWX `nfs-xattr` PVC + `workerNodes: 2` (it.161/164) -- the multi-worker shared-posix feature | `groundnuty/onedata-operator:v0.6.0` (**forward reference -- see landscape README**) |

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
