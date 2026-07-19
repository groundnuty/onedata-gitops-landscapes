# `sv-federation` / `v1`

The **scenario-2 FEDERATION landscape** (maintainer-ordered, design
it.283/287): the deepest networking validation the decomposed
per-role architecture (design it.90, merged master `7317e98`) has had.
1 Onezone + **TWO per-role-DECOMPOSED, multi-node, Composed
Oneproviders** (`provider-a` / `provider-b`), one Space supported on
**BOTH**, and the cross-provider rtransfer replication path exercised
for the first time ever on decomposed providers: write a file via
provider-a, read it back via provider-b (and the reverse). Also
re-validates scenario 1 (an Oneclient mounted against a decomposed
provider) cleanly.

This is v0.6.5's hardware debut and doubles as the reference
deployment / demo seed the it.279 north star asked for -- it **stays
running** after this session, it is not torn down.

## Deltas from `sv-posix-multinode/v2` (the pattern this landscape is modeled on)

| | v2 | sv-federation/v1 |
|---|---|---|
| Oneproviders | 1, single combined pod (no `spec.managed.topology.managerNodes` set) | **2**, each REAL per-role split (`databaseMode: Composed`, `managerNodes: 1` explicit) -- separate `cluster_manager`/`op_worker`/Couchbase StatefulSets per provider |
| Federation | N/A (single provider) | 1 Space supported by BOTH providers -- 2 `Support` CRs, different `(space, provider)` pairs, no VFS-5497 same-provider conflict |
| Storage | 1 shared RWX PVC | **2 separate** RWX PVCs, one per provider (a real cross-network test, not a trivially-shared filesystem) |
| Operator image | v0.6.5 (same) | v0.6.5 (same; the release that carries per-role decomposition) |
| RBAC | Role only (no PDB/PriorityClass rules -- see below) | Role **+ PDB rule + a separate ClusterRole/ClusterRoleBinding for `scheduling.k8s.io/priorityclasses`** (see `operator/clusterrole-priorityclass.yaml`'s header) |

## RBAC finding (it.287, new): v2's own Role has drifted a second time

`sv-posix-multinode/v2`'s vendored `operator/role.yaml` never picked up
the `policy/poddisruptionbudgets` + `scheduling.k8s.io/priorityclasses`
rules the upstream operator ClusterRole (`config/rbac/role.yaml`)
gained in commit `89cc0b9` (PDB + PriorityClass hardening for the
per-role `cluster_manager`, design it.279) -- the same "dual-release-drift"
class of defect the it.209 `cert-manager.io/certificates` fix (v2's own
role.yaml header) already named once. This is not just theoretical for
v2 either: the CRD default flip (`databaseMode` `Bundled`->`Composed`,
design it.251) means ANY Oneprovider CR that merely sets
`spec.managed.topology` is per-role by default now, so a redeployed v2
would hit this too. **This landscape's `operator/role.yaml` and the new
`operator/clusterrole-priorityclass.yaml` fix it here**; flagging for
the v2 maintainer to backport is left as a note, not done in this
landscape's own scope.

PriorityClass needed its own **ClusterRole+ClusterRoleBinding**, not
just an added Role rule: PriorityClass is cluster-scoped, and a
namespaced Role bound via a namespaced RoleBinding cannot authorize a
cluster-scoped resource request at all (no namespace on the request to
match against) -- see that file's header for the full mechanism.

## Sync waves

```
wave -1   00-namespace.yaml            the sv-federation namespace
wave  1   operator/                    namespace-scoped onedata-operator v0.6.5, --watch-namespace=sv-federation
wave  2   crs/                         demo Secrets, 2 storageVolume PVCs, Onezone, 2 Oneproviders
```

## Image pins (pull-verified from large-dev before this landscape was authored)

- **Operator:** `harbor.k8s-one-onedata.dedyn.io:30003/dev/onedata-operator:v0.6.5`
  (digest `sha256:8d8188a638838c962ca205f9655c0f9a206b5e7efaf7bb08c278f7c5e5adf9d5`)
- **Onezone:** `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-20260719-p0012.0014.0015.0016.0018.0019-on4`
  (digest `sha256:ed56ca59005d3a27fb2a9356a3a711373714663434eb2bfee7a9ad10b3e2938c`)
- **Oneprovider (both):** `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-dev:develop-20260719-p0012.0013.0014.0015.0016.0017.0018.0019.0020-on4`
  (digest `sha256:3597df164f22e7a7500a0e04ab9f78e79c438a96fece2e74934867700a6c5ba8`)

All three require the `harbor-dev-pull` imagePullSecret (private Harbor
`dev` project). `trustIssuerCA: true` is REQUIRED (not just safe) per
`deploy-test-v064.md` defect A -- see `crs/onezone.yaml`'s header.

## Gated deploy order

```sh
# CRD superset: the vendored crds/ was STALE (scaffolded 2026-07-17,
# before per-role decomposition merged) and missing managerNodes/
# growMode/ephemeralStorage* entirely -- re-vendored from
# onedata-operator@4fed69c as part of this landscape's own commit.
make apply-crds

# Platform prereqs already on k8s-one (argocd-install, dev-ca-deploy,
# Harbor) -- reused, not re-run.

make harbor-pull-secret NS=sv-federation

make deploy-landscape NAME=sv-federation VERSION=v1
# ... wait for onezone/zone, oneprovider/provider-a, oneprovider/provider-b to report Ready ...

NAMESPACE=sv-federation ./apply-dependent-crs.sh
```

## Validate (no cluster contact)

```sh
make validate-landscapes
NAMESPACE=sv-federation APPLY_CMD=cat \
  PROVIDER_A_ONEPANEL_ENDPOINT=10.0.0.1:9443 PROVIDER_B_ONEPANEL_ENDPOINT=10.0.0.2:9443 \
  ZONE_ONEPANEL_ENDPOINT=10.0.0.3:9443 \
  ./landscapes/sv-federation/v1/apply-dependent-crs.sh
```

## Known gap (unchanged from every other landscape in this repo)

StorageBackend/User/Space/Support/Oneclient are a day-2 step
(`apply-dependent-crs.sh`) -- same drive-first MVP limitation as v1/v2
(their controllers do not yet resolve a managed CR's own status for
`onepanelEndpoint`/`onezoneRef.endpoint`).
