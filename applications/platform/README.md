# `applications/platform/` -- cluster-singleton apps

This directory holds Argo CD `Application` manifests for things that
exist **once per cluster**, independent of any single landscape's
lifecycle -- as opposed to `applications/landscapes/`, where every entry
is one of potentially many versioned, individually-applied landscapes.

**Singleton vs. landscape, the distinction:**

| | `applications/platform/` | `applications/landscapes/` |
|---|---|---|
| Cardinality | one per cluster | many (one per `<landscape>-<version>`) |
| Lifecycle | tracks the cluster itself | tracks a landscape's own version history |
| Example | Harbor (private OCI registry) | `sv-posix-multinode-v1` |
| Namespace | its own dedicated namespace | its own dedicated namespace per landscape |

## Planned: Harbor (not built in this scaffold)

The first planned occupant of this directory is **Harbor**, a private
OCI/container registry for this repo's own images -- deployed via Argo
CD into its own dedicated namespace (`onedata-gitops-harbor`; an
ours/demo registry for this project, not an official Onedata cluster
service) once someone actually needs it.

**Not built here.** This scaffold only creates the directory split and
this placeholder note (per maintainer decision during the it.176
scaffolding pass). A follow-up commit will add `platform/harbor/` (the
Harbor manifests/values) and `applications/platform/harbor.yaml` (its
root Application) when that work actually starts.

## Argo CD itself is not here either

Argo CD is the **one bootstrap exception**: it cannot GitOps-deploy
itself before it exists (see the top-level README's "Argo CD itself"
section and `make argocd-install`). Its manifests live in `argocd/` and
are applied directly via `kubectl`/`kustomize`, not as an Argo
`Application` in this directory. Once Harbor (or any future platform
app) lands, *it* is Argo-managed from day one -- only Argo CD's own
install is imperative.
