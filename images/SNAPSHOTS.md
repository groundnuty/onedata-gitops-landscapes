# Upstream-image snapshots (it.230)

## Policy

**Standing maintainer policy, it.230:** never deploy a mutable Onedata
tag (`develop`, `latest`, or a Docker-Hub release tag consumed live
through `dockerhub-proxy`) into a landscape. Onedata's `develop` ==
`latest` — the exact contents behind either tag are unknown at deploy
time and can change same-day (it.229: an escript-instability defect
surfaced as a same-day, same-tag behavior change; two local `:develop`
pulls of `oneprovider-dev` and `onezone-dev` already differed by three
days of upstream commits despite both being pulled "today").

Instead: snapshot the **exact image you just pulled and validated**
into this repo's private Harbor `dev` project under a **dated tag**
(`<name>:<source-tag>-YYYYMMDD`). A landscape's `spec.managed.image`
(or the operator Deployment's own image pin) always points at a dated
snapshot, never at the mutable upstream ref directly. Updating a
snapshot — re-running the snapshot for a given name/date, or cutting a
new date for the same upstream `:develop` — is a **conscious decision**
each time, gated behind `make snapshot-image ... FORCE=1`.

Mechanism: `make snapshot-image SRC=<ref> NAME=<harbor-repo-name>
[DATE=YYYYMMDD] [NOPULL=1] [FORCE=1]` (see the Makefile target's own
`## ` help line, or `make help`). It pulls `SRC` (unless `NOPULL=1`,
for the case where `SRC` was already pulled and validated earlier in
the same session and a fresh pull risks silently swapping bits under
the mutable tag), tags + pushes it to
`$(HARBOR_HOST)/dev/<NAME>:<source-tag>-<DATE>`, captures the local
image ID, the upstream image's own `Created` timestamp (its real build
date, not the pull date), and the pushed repo digest, and appends a row
below. The "Validated by" column is **not** auto-filled — it must be
edited in by hand before committing, pointing at whatever evidence
(design-log iteration, `research/*.md`, a specific landscape deploy)
actually exercised the image.

## Snapshots

| Snapshot date | Source ref | Harbor target | Upstream build date | Image ID | Digest | Validated by |
|---|---|---|---|---|---|---|
| 2026-07-18 | `docker.onedata.org/oneprovider-dev:develop` | `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-dev:develop-20260718` | 2026-07-15 | `11eca6bd…` | `sha256:55afb9e4…` | it.230 first-snapshot pull, validated by the truthful-status / patch-0013 live proofs run against this exact image (design log it.235/it.237); `research/patch-0013.md`; re-pinned into `sv-posix-multinode/v1` (this sweep, it.238). |
| 2026-07-18 | `docker.onedata.org/onezone-dev:develop` | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-20260718` | 2026-07-12 | `2d9df795…` | `sha256:f2353a44…` | it.230 first-snapshot pull, paired with the oneprovider-dev snapshot above (matching `-dev` nightly lineage — mismatched lineages are a confirmed GraphSync-refusal defect, `research/m3-live-proof.md` §2); re-pinned into `sv-posix-multinode/v1` (this sweep, it.238). |

Full imageID/digest values are recorded in the design log (it.230
entry, `deliverables/onedata-operator-design.md` in the design repo) —
the truncated `…` forms above are the values as received from the
maintainer; replace with the full 64-hex values here once re-verified
against Harbor (`docker manifest inspect`) from a session with an
active Harbor login, rather than re-typing from memory.

## Release-tag candidates (not yet snapshotted)

These are release-style tags (not `:develop`/`:latest`) currently
pulled live through Harbor's public `dockerhub-proxy` proxy-cache
project. They are technically still mutable — Docker Hub does not
guarantee a release tag's digest never changes — but they are lower
risk than `:develop`/`:latest` (Onedata release tags are not
continuously rebuilt the way the nightly `-dev` lineage is), and
`dockerhub-proxy` is a cache of an already-public image, not a private
push target. Per it.230/it.238, these are **noted here as candidates
for future digest-pinning, not snapshotted** — deciding to spend a
Harbor push on a public, already-versioned release image is left to
the maintainer rather than done speculatively by this sweep:

| Landscape | Image ref (via `dockerhub-proxy`) | Note |
|---|---|---|
| `sv-posix-multinode/v2` | `harbor.k8s-one-onedata.dedyn.io:30003/dockerhub-proxy/onedata/oneprovider:21.02.7` | Actively deployed by v2's `crs/oneprovider.yaml`. Candidate for a `make snapshot-image SRC=harbor.../dockerhub-proxy/onedata/oneprovider:21.02.7 NAME=oneprovider FORCE=1`-style re-tag (or a plain digest pin, `image: ...oneprovider:21.02.7@sha256:...`) if/when the maintainer wants this landscape fully immutable too. Left unchanged by this sweep. |
| `sv-posix-multinode/v2` | `harbor.k8s-one-onedata.dedyn.io:30003/dockerhub-proxy/onedata/onezone:21.02.7` | Same as above, paired zone image. Left unchanged by this sweep. |

## Frozen one-off tags (pre-date this manifest, not re-pinned)

| Landscape | Image ref | Note |
|---|---|---|
| `sv-livegrow/v1` | `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-patched:dynmem-livegrow-hw1` | A locally patched core image (cumulative DYNAMIC_MEMBERSHIP patchset beams, design it.209), pushed once under this specific tag and never overwritten since. Not a bare `:develop`/`:latest` ref — the tag itself is the pin. No re-pin needed. |
| `sv-livegrow/v1` | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-livegrow-hw1` | `docker.onedata.org/onezone-dev:develop` pulled once (design it.209) and pushed under this specific, never-reused tag to match the patched provider's `-dev` lineage. Predates the `it.230` `<name>:<tag>-YYYYMMDD` naming convention and is a completed hardware-campaign artifact (M3 elasticity campaign, CLOSED) — left as-is rather than renamed for naming-convention consistency alone. |
