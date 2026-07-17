# CRDs: the one shared, cluster-scoped resource

Every primitive CRD (`Onezone`, `Oneprovider`, `StorageBackend`, `Space`,
`Support`, `User`, `Group`, `Oneclient`, and `testing.onedata.org`'s
`TestStorageFixture`) is **cluster-scoped** -- there is exactly one copy
per cluster, no matter how many landscapes (each with its own
namespace-scoped operator instance, possibly a different operator
*version*) exist side by side.

## The superset/latest rule

These files are a **vendored, point-in-time copy** of
`onedata-operator`'s `config/crd/bases/*.yaml` at the commit this repo
was scaffolded against
(`groundnuty/onedata-operator@af444380a746fd834690ed61494cef9fc3850dc3`, master, 2026-07-17).

Because the operator repo's CRD evolution is **additive-only** (new
optional fields, new enum values -- never a removed or renamed field;
see that repo's own design-doc discipline), **the newest CRD set on disk
here is always a superset of every older one**. That is what makes it
safe for landscapes pinning *different* operator versions to share this
one CRD set: an older-pinned operator simply never populates the fields
a newer CRD schema added, and never breaks reading its own.

**Rule when adding a new landscape:** if that landscape's operator image
is newer than the CRDs currently vendored here, update this directory
(`cp <operator-repo>/config/crd/bases/*.yaml crds/`) as part of that
landscape's own PR, **before** its `Application` manifest lands. Never
downgrade this directory -- only ever move it forward.

## Why not an Argo `Application`

CRDs are applied via `make apply-crds` (plain `kubectl apply -k crds/`),
**not** wrapped in an Argo CD `Application`. Reasons:

- It is a genuine **cluster-scoped, once-per-cluster prerequisite** --
  Argo CD itself doesn't exist yet the very first time this runs (see
  the mandatory deploy sequence in the top-level README), so it cannot
  be the thing that installs its own CRD prerequisite chicken-and-egg
  style, and even after Argo CD exists, giving it ownership of a
  cluster-wide singleton that every landscape's namespace depends on
  would make "delete one landscape's Application" a plausible (and
  catastrophic) path to accidentally pruning the CRDs every *other*
  landscape also depends on.
- CRDs change rarely relative to landscape CRs; a manual, explicit,
  reviewed `make apply-crds` per superset bump is the right cadence.
