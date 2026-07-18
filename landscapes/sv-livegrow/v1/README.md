# sv-livegrow / v1

Proves **TRUE LIVE WORKER GROW** (design it.173/175/182/189) on real
k8s-one multi-node hardware -- the hardware upgrade of the minikube-only
proof (`research/livegrow-build.md`: grow 1->2 workers in 67s, 2->3 in
~90s, 0 non-200 responses across 373 polls against pre-existing
endpoints, zero pod restarts, storage-serving proven end-to-end via the
operator's `InitSpaceCaches` RPC).

Deploys into its own `sv-livegrow` namespace, alongside (never
in-place-of) `sv-posix-multinode` (v1) -- modeled directly on
`sv-posix-multinode/v2`'s productionized pattern (dev-CA TLS + Harbor
images + a v0.6.1 operator pin), with two deltas:

1. **The Oneprovider image is core-patched, not vanilla.**
   `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-patched:
   dynmem-livegrow-hw1` -- the cumulative DYNAMIC_MEMBERSHIP patchset
   image (`oneprovider-dev:livegrow` in large-dev's local docker daemon,
   reused as-is from the minikube proof session, retagged+pushed here)
   in Harbor's **private** `dev` project. Per design it.209's explicit
   directive, this is the only approved destination for a patched core
   image leaving large-dev -- never any Onedata registry, never Docker
   Hub.
2. **The Onezone image must match the `-dev` nightly lineage.**
   `docker.onedata.org/onezone-dev:develop`, not the vanilla release --
   pairing a `-dev` nightly provider with a vanilla-release zone is a
   confirmed defect (`m3-live-proof.md` §2: permanent GraphSync
   refusal on a version mismatch). Needs the external
   `docker-onedata-org` imagePullSecret, same prerequisite
   `sv-posix-multinode/v1` documents.

The operator image itself stays the plain, already-proven
`harbor.../dev/onedata-operator:v0.6.1` -- `growMode: Live` merged into
operator master at it.189 and is an ancestor of the v0.6.1 tag
(verified via `git merge-base --is-ancestor`), so no new operator image
was built or pushed for this landscape.

## The proof sequence (manual, evidence-gathering -- not automated)

1. Deploy at `workerNodes: 1, growMode: Live` (zero-effect at 1 node).
2. `apply-dependent-crs.sh` -> register + create `sv-space` + write a
   baseline set of checksummed files through the single worker.
3. Start a 1/s serving-poll against the existing worker's endpoint.
4. **The grow, driven through git**: bump
   `spec.managed.topology.workerNodes` to `2` in
   `crs/oneprovider.yaml`, commit, let Argo (or a manual sync) apply
   it. Measure: time-to-serving for the new worker via its OWN
   endpoint (write+read+peer-readback checksum-clean), disruption on
   the pre-existing worker(s) (non-200 count in the poll), and pod
   identity continuity (zero restarts expected on existing pods).
5. If cluster capacity headroom allows, repeat for `workerNodes: 3`.
6. Evidence written to `large-dev:/mnt/data/work/phase4/livegrow-hardware.md`.
7. Teardown via the Argo cascade-finalizer pattern (see the top-level
   README's teardown section) once evidence is captured -- manifests
   stay in git, redeployable at any time.

## External prerequisites (not created by this repo)

- **`docker-onedata-org` imagePullSecret**, in the `sv-livegrow`
  namespace, holding real credentials for the private
  `docker.onedata.org` registry -- genuine infra credentials,
  deliberately *not* committed here. Same prerequisite
  `sv-posix-multinode/v1` already documents; copy/recreate from that
  namespace's existing secret of the same name (or the maintainer's
  canonical source) into `sv-livegrow`.
- **`make harbor-pull-secret NS=sv-livegrow`** -- both the operator
  image and the patched Oneprovider image are in Harbor's private
  `dev` project.
- **`onedata-dev-ca` ClusterIssuer Ready** (`make dev-ca-deploy`) --
  same TLS prerequisite as v2.
- Steps 1-3 of the top-level README's mandatory deploy sequence
  (`scope-cluster-manager`, `apply-crds`, `argocd-install`) already
  applied to the target cluster (they are -- this landscape deploys
  onto the same already-provisioned k8s-one platform v1/v2 used).

## Capacity note

Design it.209's `sv-posix-multinode/v2` deploy hit a real DiskPressure
incident driven by the managed Oneprovider container's own
ephemeral-storage footprint (~21GiB, Bundled Couchbase co-located, no
resource request/limit -- an unfixed v0.6.2 backlog item) against
k8s-one's "small" node flavor (~24GiB capacity). This landscape is kept
deliberately small (workerNodes starts at 1, PVC is 2Gi) and its
deploy/grow is watched against live node `DiskPressure` conditions
throughout -- see `phase4/livegrow-hardware.md` for what was actually
observed.
