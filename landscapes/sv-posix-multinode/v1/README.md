# `sv-posix-multinode` / `v1`

A minimal, hermetic Onedata landscape staged for the
**`storageVolume`-on-RWX-NFS test** (design it.161/164): does a managed
Oneprovider's `op_worker` actually share one `posix` mount identically
across multiple worker pods, with no per-pod `subPathExpr`, when that
mount is a real dynamically-provisioned RWX PVC (not a
`TestStorageFixture`, not a single-worker `StorageClass`-governed PVC)?

Deliberately **NOT** a scaled-down `demo/landscape-max` -- it seeds the
smallest graph that actually exercises the feature:

| Kind | Count | Names |
|---|---|---|
| Onezone | 1 | `zone` |
| Oneprovider | 1 | `provider` (`spec.managed.topology.workerNodes: 2`, `spec.managed.storageVolume` -> the PVC below) |
| PersistentVolumeClaim | 1 | `sv-posix-multinode-shared-posix` (RWX, `storageClassName: nfs-xattr`) |
| StorageBackend | 1 | `provider-posix` (`type: posix`, register-only, day-2 script -- see below) |
| Space | 1 | `sv-space` (day-2 script) |
| User | 1 | `scientist` (day-2 script) |
| Support | 1 | `sv-support` (links `sv-space` to `provider-posix`, day-2 script) |

## Sync waves

```
wave -1   00-namespace.yaml            the sv-posix-multinode namespace
wave  0   01-cert-config.yaml          self-signed Issuer + Certificate (it.165 L1 test path)
wave  1   operator/                    namespace-scoped onedata-operator, --watch-namespace=sv-posix-multinode
wave  2   crs/                         demo Secrets, the storageVolume PVC, Onezone, Oneprovider
```

## Image pin -- FORWARD REFERENCE, not yet deployable

`operator/deployment.yaml` pins **`groundnuty/onedata-operator:v0.6.0`**,
which **does not exist yet** as of this scaffold. `v0.6.0` will be
tagged and published once the in-flight cold-scale-up work merges to
`master`, **before** this landscape's first gated deploy. This
landscape structurally needs a post-`v0.5.0` build:
`spec.managed.storageVolume` and `spec.managed.topology.workerNodes`
(it.161/164) both post-date the currently-deployed `v0.5.0` image, which
would **silently drop** them rather than erroring (no schema in
`v0.5.0` knows either field exists) -- exactly the danger the top-level
README's mandatory-sequence step 1 (`scope-cluster-manager`) exists to
contain for every *other* landscape, and the reason this landscape
cannot simply reuse `v0.5.0` for itself either.

**Do not run `make deploy-landscape NAME=sv-posix-multinode VERSION=v1`
until `groundnuty/onedata-operator:v0.6.0` is confirmed pullable.**

## Known gap: StorageBackend/User/Space/Support are a day-2 step

`StorageBackend.spec.onepanelEndpoint` and `User.spec.onepanelEndpoint`
are the managed Oneprovider's/Onezone's onepanel **pod IP** -- not
knowable until that CR reaches `Ready`, and therefore not something a
static git-committed manifest can carry (see the top-level README's
"Known gaps" section for the source-level confirmation). This is the
same, already-accepted limitation `demo/landscape-3p` and
`demo/landscape-max` in the operator repo both document and route around
with a small apply script read live against the cluster.

This landscape follows the identical precedent:

```sh
# after `make deploy-landscape NAME=sv-posix-multinode VERSION=v1` AND
# after onezone/zone + oneprovider/provider both report Ready:
NAMESPACE=sv-posix-multinode ./apply-dependent-crs.sh
```

Applies, in order, waiting for each to go `Ready` before the next:
`StorageBackend/provider-posix` -> `User/scientist` (+ waits for its
minted access-token Secret) -> `Space/sv-space` -> `Support/sv-support`.

A cleaner, fully-Argo-native version of this (an Argo `PostSync` hook
`Job` running the same script, so the whole landscape converges without
a human running a script) is a good follow-up -- flagged here, not built
in this scaffold, to keep this landscape's v1 scope to exactly what
it.176 asked for.

## External prerequisites (not created by this repo)

- **`docker-onedata-org` imagePullSecret**, in the `sv-posix-multinode`
  namespace, holding real credentials for the private
  `docker.onedata.org` registry -- genuine infra credentials, correctly
  *not* committed here (unlike `crs/secrets.yaml`'s demo creds). Same
  prerequisite `demo/landscape-3p`/`demo/landscape-max` already
  document.
- **`groundnuty/onedata-operator:v0.6.0`** pullable from Docker Hub --
  see "Image pin" above.
- Steps 1-3 of the top-level README's mandatory deploy sequence
  (`scope-cluster-manager`, `apply-crds`, `argocd-install`) already
  applied to the target cluster.

## Validate (no cluster contact)

```sh
make validate-landscapes   # kustomize build + kubectl apply --dry-run=client, this landscape included
NAMESPACE=sv-posix-multinode APPLY_CMD=cat \
  PROVIDER_ONEPANEL_ENDPOINT=10.0.0.1:9443 ZONE_ONEPANEL_ENDPOINT=10.0.0.2:9443 \
  ./landscapes/sv-posix-multinode/v1/apply-dependent-crs.sh   # renders the day-2 CRs offline, same convention as demo/landscape-max's own scripts
```
