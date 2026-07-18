# Argo CD install (dedicated namespace)

`kustomize build argocd/` renders the **upstream Argo CD `v3.4.4` install
manifest** (`vendor/install-v3.4.4.yaml`, fetched verbatim from
`https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml`
-- pinned by tag, not `stable`/`latest`), relocated into the dedicated
namespace `onedata-gitops-argocd` via kustomize's `namespace:` transformer,
plus a small `argocd-cm` patch adding the Onedata health-check Lua
(`argocd-cm-patch.yaml`).

Cluster-wide RBAC (Argo CD needs to manage every landscape's namespace).
Basic/insecure auth, generated initial-admin password. **Not exposed via
any Ingress/LoadBalancer** -- reach it only through `make argocd-ui`
(a `kubectl port-forward`, localhost-only). This is a deliberate demo
trade-off (it.176), not a production posture.

## Why no `namePrefix`

Argo CD's own binaries (`argocd-server`, `repo-server`,
`application-controller`) look up `argocd-cm`, `argocd-secret`,
`argocd-rbac-cm`, etc. by a **hardcoded literal name**, not through any
parameterized env var in the upstream manifests. Renaming those objects
via a kustomize `namePrefix`/`nameSuffix` would silently break the
install (the server pod comes up healthy but can never find its own
config). The supported way to run an isolated Argo CD instance is a
**dedicated namespace** -- which every Argo CD binary does respect (via
its own pod's namespace) -- so `namespace: onedata-gitops-argocd` is the
only transform this kustomization applies. Every resource name stays
exactly as upstream ships it (`argocd-server`, `argocd-cm`, ...).

## `ignoreDifferences`: which form, and why

Design it.176 flagged this as "Hole 1": Argo CD's `ignoreDifferences` can
be expressed either as `managedFieldsManagers` (server-side-apply field
ownership) or as `jsonPointers`/`jqPathExpressions` (plain path-based).

**We use the `jsonPointers` (path-based) form.** Verified by source
inspection of the operator repo
(`git.onedata.org`... no -- `github.com/groundnuty/onedata-operator`,
`internal/controller/*.go`):

- **No server-side-apply anywhere.** `grep -rn "client.Apply\|FieldOwner\|types.ApplyPatchType" internal/`
  returns zero hits outside test files. Every mutation is a plain typed
  `r.Update(...)` / `r.Status().Update(...)` call -- there is no
  competing field manager to reconcile `managedFieldsManagers` against.
- **The only fields any reconciler ever writes back onto a CR's `spec`**
  (as opposed to its `status` subresource) are via
  `controllerutil.AddFinalizer`/`RemoveFinalizer`, i.e. **exactly
  `metadata.finalizers`**. Confirmed for every managed-lifecycle
  controller (`oneprovider_managed.go`, `onezone_managed.go`,
  `oneclient_controller.go`) -- no other spec field is ever
  operator-defaulted or operator-mutated post-creation.

So each landscape's root `Application` (see
`applications/landscapes/*.yaml`) carries, per onedata.org/testing.onedata.org
kind it declares:

```yaml
ignoreDifferences:
  - group: onedata.org
    kind: Oneprovider
    jsonPointers:
      - /status
      - /metadata/finalizers
  # ... one entry per kind the landscape's CRs actually use
```

`/status` because every reconciler owns and continuously rewrites its
CR's status subresource (phase, conditions, IDs, endpoints -- none of it
declared in git, all of it legitimately live-only). `/metadata/finalizers`
because the operator adds its own lifecycle finalizer on first reconcile,
which git's static manifest never declares either.

**Not covered, and not needed:** CRD-schema-level defaulting (e.g.
`Oneprovider.spec.managed.enabled`'s `+kubebuilder:default=false`,
`Group.spec.memberGroups[].type`'s `+kubebuilder:default=team`) is
applied by the API server itself at admission time, for every writer
(kubectl, Argo, anyone) -- not operator-specific -- and Argo CD's own
diff normalization already accounts for API-server-side defaulting in
the common case, so no additional `ignoreDifferences` entry is needed
for it here.

## Health check

See `argocd-cm-patch.yaml` for the actual Lua (one ~10-line body per
Onedata CRD kind, reading `.status.phase`). CRD-level
`additionalPrinterColumns` already exist upstream (including a `Phase`
column) -- this patch is the other half: it makes Argo's own
`Application` health rollup (and therefore the whole-landscape green/red
tile) key off the exact same field.

## `make argocd-install` uses `--server-side --force-conflicts` (it.198 defect #1, closed)

`argocd/vendor/install-v3.4.4.yaml` bundles two very large CRDs:
`applicationsets.argoproj.io` (~1.4MB) and `applications.argoproj.io`
(~368KB). Plain client-side `kubectl apply` computes a
`kubectl.kubernetes.io/last-applied-configuration` annotation holding
the whole submitted object as JSON -- and Kubernetes caps total
annotation size at 256KiB (262144 bytes) per object. Both CRDs blow
past that ceiling, so `kubectl apply -k argocd/` fails outright on
**any** cluster, not something k8s-one-specific.

The first live deploy (`research/gitops-first-deploy.md`, defect #1)
hit exactly this and was worked around by hand with `--server-side`.
That workaround was never folded back into the `argocd-install` target
itself, so every subsequent run would re-hit the failure. Fixed here:
the target now runs `kubectl apply --server-side --force-conflicts -k
argocd/`. Server-side apply tracks field ownership instead of a
single monolithic annotation, so the size ceiling never applies;
`--force-conflicts` keeps the target idempotent across re-runs (a
version bump, or a prior client-side apply/different field manager
already owning some fields).

**Checked, not affected:** `crds/` (the onedata.org/testing.onedata.org
CRD superset) stays on plain client-side `apply -k` -- measured
2026-07-18 via `yq -o=json` on each file, the largest
(`onedata.org_oneproviders.yaml`) serializes to ~171.6KB, comfortably
under the 256KiB ceiling with ~90KB headroom. `platform/harbor/`'s and
`platform/cert-manager-desec/`'s vendored renders are smaller still
(54KB and 12KB total, respectively, across ALL their documents
combined) and pose no risk either. Revisit the `crds/` measurement if
a future onedata.org CRD schema grows substantially.
