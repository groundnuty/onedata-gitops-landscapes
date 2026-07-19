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

## Consolidated patched images (core-mod campaign, it.268)

Not upstream-pull snapshots (the `## Snapshots` table above is for those) --
these are **locally patched core images**, same category as the "Frozen
one-off tags" section: a dated vanilla snapshot (`## Snapshots` table above)
as `FROM` base, with proven core patches layered on top as beam-overlay
`COPY` instructions (source: canonical `operator-patchset` checkouts at
`large-dev:/mnt/data/work/phase4/patchset-src/`), tag itself is the pin.
All flags **default OFF** -- verified byte-identical vanilla boot behavior
(matching stock-image startup logs line-for-line at the config-less boot
stage); a landscape opts in per-flag via `/etc/default/<component>` mounts.
Full build evidence, checkout tips, and verification detail:
`large-dev:/mnt/data/work/phase4/consolidated-build.md`.

| Date | Image | Base snapshot | Patch composition | Image ID | Digest | Flags | Validated by |
|---|---|---|---|---|---|---|---|
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-dev:develop-20260719-p0012.0013.0014.0015.0016.0017.0018.0019.0020` | `oneprovider-dev:develop-20260718` (`sha256:55afb9e4…`) | op_worker 0013 (rtransfer_config CA-bundle filter) + 0017 (oz_domain boot-derive); helpers 0020 (NFS conn-pool revalidate, C++); onepanel 0012 (disterl-TLS) + 0014 (F12 hosts-translator) + 0016 (registered-boot idempotence); cluster_manager 0015 (NODE_DOWN_GUARD) + 0019 (CHASH_ACCESSOR_GUARD composition); ctool 0018/0019 (CHASH_ACCESSOR_GUARD, composed into cluster_manager's own vendored ctool copy only) | `sha256:22b86cc5aabd…` | `sha256:f0c4b7c8dada8d6236ed994393e63e12ddc019d7ef12ec05cb4c7256490aa8fa` | RTRANSFER_CA_FILTER, OZ_DOMAIN_BOOT_DERIVE, HELPER_CACHE_REVALIDATE, DISTERL_TLS, F12_HOSTS_FIX, REGISTERED_BOOT_IDEMPOTENCE, NODE_DOWN_GUARD, CHASH_ACCESSOR_GUARD -- all default OFF; disterl node_package env.sh mechanism fix baked unconditionally (no-op unless DISTERL_TLS=true) | it.268 consolidated build: all 3 component builds rc=0 under `flock build.lock`; 10 patched beams + helpers_nif.so load-verified via `erl code:load_file` + NIF on_load through the real `helpers` module; container boot A/B vs stock `oneprovider-dev:develop-20260718` byte-identical at the config-less boot stage (both: "Starting op_panel..." then wait, no crash, 20-45s observed). Full detail: `consolidated-build.md`. |
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-20260719-p0012.0014.0015.0016.0018.0019` | `onezone-dev:develop-20260718` (`sha256:f2353a44…`) | onepanel 0012 (disterl-TLS) + 0014 (F12 hosts-translator) + 0016 (registered-boot idempotence); cluster_manager 0015 (NODE_DOWN_GUARD) + 0019 (CHASH_ACCESSOR_GUARD composition); ctool 0018/0019 (CHASH_ACCESSOR_GUARD, composed into cluster_manager's own vendored ctool copy only). No op_worker/helpers patches (onezone has no op_worker component); oz_worker itself untouched/stock (out of scope). | `sha256:cb4e47159c48…` | `sha256:fa567c5dfa225904ce1b0497ccdc3c1589a1248fd8c4f7ea86859c639c593123` | DISTERL_TLS, F12_HOSTS_FIX, REGISTERED_BOOT_IDEMPOTENCE, NODE_DOWN_GUARD, CHASH_ACCESSOR_GUARD -- all default OFF; disterl env.sh fix baked unconditionally | it.268 consolidated build: same verification as the oneprovider row above (onepanel/cluster_manager beams shared codebase), container boot A/B vs stock `onezone-dev:develop-20260718` byte-identical at the config-less boot stage. Full detail: `consolidated-build.md`. |
