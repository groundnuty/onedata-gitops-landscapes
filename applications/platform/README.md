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

## Harbor (built -- it.178/179/183)

**`harbor.yaml`** points at `platform/harbor/` (dedicated namespace
`onedata-gitops-harbor`): a Docker Hub proxy-cache project
(`dockerhub-proxy`, public, frictionless pulls from any of the 22
k8s-one nodes) plus a private `dev` project that is the authorized
push target for feature-branch operator images and maintainer-approved
patched Onedata core images (it.183). See `platform/harbor/README.md`
for the full design writeup (helm-vendored-vs-Argo-Helm-source choice,
exposure/TLS trade-off, config-as-code robot-account model,
storage-retain policy) and the top-level `README.md`'s "Using the
Harbor proxy-cache from a landscape" section for how a landscape
actually consumes it.

Applied the same way as any landscape's root Application --
individually, deliberately (`make harbor-deploy`), never
auto-discovered -- but its own lifecycle is independent of any single
landscape's: `make harbor-deploy` can run any time after `make
argocd-install`, in any order relative to `make deploy-landscape`
calls.

**GATED, same as every landscape:** schema-valid and dry-run-clean
(`make validate`), NOT yet applied to k8s-one. Deploys stay gated on
the maintainer's ordered sequence (top-level README's "Mandatory
deploy sequence").

## Argo CD itself is not here either

Argo CD is the **one bootstrap exception**: it cannot GitOps-deploy
itself before it exists (see the top-level README's "Argo CD itself"
section and `make argocd-install`). Its manifests live in `argocd/` and
are applied directly via `kubectl`/`kustomize`, not as an Argo
`Application` in this directory. Harbor, and every future platform app,
*is* Argo-managed from day one -- only Argo CD's own install is
imperative.
