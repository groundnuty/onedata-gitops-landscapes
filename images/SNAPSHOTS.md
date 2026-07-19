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

## Flags-ON overlay images (v0.6.5 release train, the delete+flip pairing)

Overlay images `FROM` the `## Consolidated patched images` snapshots above,
baking exactly 4 flags ON via `/etc/default/<component>` (same mechanism,
see that section's own header) -- the **`-on4`** flag set, distinct from
the (unpushed-to-this-manifest) bundle-A/B `-bundleab-on` overlay, which
also carries `CHASH_ACCESSOR_GUARD` ON. `-on4` deliberately leaves
`CHASH_ACCESSOR_GUARD` OFF: its recovery-path co-safety gap (`0019-C`) is
not in the consolidated image these overlays are built from (see
`v065-gate.md` Cell A §3.3) -- 0018 flip-ON is gated on the next
consolidated image including `0019-C`. This is the image pair
`sv-posix-multinode/v2` re-pins to as part of the v0.6.5 operator delete
pass (`deliverables/core-fix-ledger.md`) -- the pairing is deliberate: an
operator that deletes a heal must never run against a landscape whose
image still needs that heal.

| Date | Image | Base | Flags ON | Flags OFF (deliberate) | Image ID | Digest | Validated by |
|---|---|---|---|---|---|---|---|
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-dev:develop-20260719-p0012.0013.0014.0015.0016.0017.0018.0019.0020-on4` | `oneprovider-dev:develop-20260719-p0012.0013.0014.0015.0016.0017.0018.0019.0020` (`sha256:f0c4b7c8…`) | `REGISTERED_BOOT_IDEMPOTENCE` (0016), `OZ_DOMAIN_BOOT_DERIVE` (0017), `F12_HOSTS_FIX` (0014), `NODE_DOWN_GUARD` (0015) | `CHASH_ACCESSOR_GUARD` (0018/0019 -- 0019-C recovery-path fix not in this image), `DISTERL_TLS` (0012, structural first-boot blocker), `RTRANSFER_CA_FILTER` (0013, individually proven, not composition-tested with this set), `HELPER_CACHE_REVALIDATE` (0020, individually proven, not composition-tested with this set) | `sha256:37a415c63d9b…` | `sha256:3597df164f22e7a7500a0e04ab9f78e79c438a96fece2e74934867700a6c5ba8` | Standalone `docker run` boot (FQDN hostname, so nodetool's longnames connection resolves) + `nodetool rpcterms os getenv` against the LIVE op_panel beam: `REGISTERED_BOOT_IDEMPOTENCE="true"`, `F12_HOSTS_FIX="true"`, all other 6 flags `false` -- exact 4-flag set confirmed reaching the beam, not just file presence. `/etc/default/{op_panel,op_worker,cluster_manager}` file contents also directly verified (op_worker/cluster_manager beams do not start standalone without a full onepanel-driven deploy -- out of scope for a git-side flip, see `v065-release.md`). |
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-20260719-p0012.0014.0015.0016.0018.0019-on4` | `onezone-dev:develop-20260719-p0012.0014.0015.0016.0018.0019` (`sha256:fa567c5d…`) | `REGISTERED_BOOT_IDEMPOTENCE` (0016), `F12_HOSTS_FIX` (0014), `NODE_DOWN_GUARD` (0015) (`OZ_DOMAIN_BOOT_DERIVE` is oneprovider-only, not applicable) | Same 4 as the oneprovider row above (`CHASH_ACCESSOR_GUARD`/`DISTERL_TLS`/`RTRANSFER_CA_FILTER`/`HELPER_CACHE_REVALIDATE`) | `sha256:80952cd01450…` | `sha256:ed56ca59005d3a27fb2a9356a3a711373714663434eb2bfee7a9ad10b3e2938c` | Standalone `docker run` boot (FQDN hostname) + `nodetool rpcterms os getenv` against the LIVE oz_panel beam: `REGISTERED_BOOT_IDEMPOTENCE="true"`, `F12_HOSTS_FIX="true"`, all other 6 flags `false`. `/etc/default/{oz_panel,cluster_manager}` file contents also directly verified. |

Re-pinned into `sv-posix-multinode/v2` (`crs/oneprovider.yaml`,
`crs/onezone.yaml`) as part of the v0.6.5 release train -- see those
files' own `IMAGE`/`RE-PINNED` header notes.


## P5 close-out consolidated images (it.295-closeout, 2026-07-19/20)

Supersede the it.268 consolidated build -- adds 0022 (`DURABLE_CM_BARRIER`, cluster_worker
`node_manager.erl`, compiled as part of BOTH op_worker's AND oz_worker's own release this
session), 0023 (`REJOIN_NODES`, onepanel `service_onepanel.erl`), 0019c (`safe_report_node_recovery`,
cluster_manager -- unconditional correctness fix, no flag). Same it.230 dated vanilla snapshot
bases as it.268 (no base-image change). oz_worker built for the FIRST time this campaign (was
never touched before -- see `p5-closeout.md` sec 2); its own release now also carries the
0022-patched `node_manager.beam`.

| Date | Image | Base snapshot | Patch composition | Image ID | Digest | Validated by |
|---|---|---|---|---|---|---|
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-dev:develop-20260719-p0012.0013.0014.0015.0016.0017.0018.0019.0019c.0020.0022.0023` | `oneprovider-dev:develop-20260718` (`sha256:55afb9e4…`) | op_worker 0013+0017 (unchanged); cluster_worker **0022 NEW** (compiled as op_worker's own release dep); helpers 0020 (unchanged); onepanel 0012+0014+0016+**0023 NEW**; cluster_manager 0015+0019+**0019c NEW**; ctool 0018/0019 (cluster_manager's own vendored copy only) | `sha256:0ce1a8e2da17…` | `sha256:4e97a9de82530d41031803af81e79a0834426050d5ae6975db34678b8d0757b1` | it.295-closeout: real integrated release build via wrapper-scripts under `flock build.lock` (op_worker's own top-level rebar pins bumped to current ctool/cluster_manager/cluster_worker tips -- fixes the it.294 stale-pin gap); op_worker leg compiled `cluster_manager`+`cluster_worker` in-graph with ZERO errors (settles the "nominal vs real" QUERY_STATUS-macro risk); all 11 changed beams `code:load_file` OK; container boot A/B vs stock `develop-20260718` byte-identical. Full detail: `p5-closeout.md` secs 1-6. |
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-20260719-p0012.0014.0015.0016.0018.0019.0019c.0022.0023` | `onezone-dev:develop-20260718` (`sha256:f2353a44…`) | cluster_worker **0022 NEW** (compiled as oz_worker's own release dep -- oz_worker's FIRST build this campaign, previously untouched); onepanel 0012+0014+0016+**0023 NEW**; cluster_manager 0015+0019+**0019c NEW**; ctool 0018/0019 (cluster_manager's own vendored copy). oz_worker itself carries zero own-source patches. | `sha256:df176217e2b4…` | `sha256:8884f21dea27d823bacc890f82829ec35dd20165361dc072db9e500c4d73730a` | it.295-closeout: oz-worker-int checkout established from scratch on an `operator-patchset` branch (never existed before), pins bumped to current tips, `bamboos` submodule re-pointed+initialized (same it.121-class gotcha as cluster_manager/cluster_worker); real build DONE rc=0, zero errors; `node_manager.beam` carries `durable_cm_barrier_enabled`; all beams load OK; boot A/B byte-identical vs stock. Full detail: `p5-closeout.md` secs 2, 4, 6. |

## Flags-ON overlay images (P5 close-out, the `-on7` set)

Overlay `FROM` the P5 close-out consolidated snapshots above, baking **7** flags ON via
`/etc/default/<component>` (same durable-mount mechanism) -- the -on4 four PLUS `REJOIN_NODES`,
`DURABLE_CM_BARRIER`, and `CHASH_ACCESSOR_GUARD` (the last now legal: 0019c closes the
recovery-path interaction that made it unsafe to enable in `-on4`/`-bundleab-on`). OFF (unchanged):
`DISTERL_TLS`, `RTRANSFER_CA_FILTER`, `HELPER_CACHE_REVALIDATE`.

| Date | Image | Base | Flags ON | Flags OFF | Image ID | Digest | Validated by |
|---|---|---|---|---|---|---|---|
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/oneprovider-dev:develop-20260719-p0012.0013.0014.0015.0016.0017.0018.0019.0019c.0020.0022.0023-on7` | the P5 close-out oneprovider row above | `REGISTERED_BOOT_IDEMPOTENCE`, `F12_HOSTS_FIX`, `OZ_DOMAIN_BOOT_DERIVE`, `NODE_DOWN_GUARD`, `REJOIN_NODES`, `DURABLE_CM_BARRIER`, `CHASH_ACCESSOR_GUARD` | `DISTERL_TLS`, `RTRANSFER_CA_FILTER`, `HELPER_CACHE_REVALIDATE` | `sha256:3b024c644064…` | `sha256:79d77863c5bf3058642c5ffa8238c0bab641b208ce725abbad2e59655bf36cc2` | `nodetool rpcterms os getenv` against the live op_panel beam (FQDN-hostname `docker run`): `REGISTERED_BOOT_IDEMPOTENCE="true"`, `F12_HOSTS_FIX="true"`, `REJOIN_NODES="true"`, all other 7 flags `false` -- exact set confirmed. `/etc/default/{op_worker,cluster_manager}` file contents verified for `OZ_DOMAIN_BOOT_DERIVE`/`DURABLE_CM_BARRIER`/`NODE_DOWN_GUARD`/`CHASH_ACCESSOR_GUARD` (beams don't start standalone). A real authoring bug (missing `export` in the flag files, silently non-propagating) was found and fixed during this verification -- see `p5-closeout.md` sec 8. |
| 2026-07-19 | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onezone-dev:develop-20260719-p0012.0014.0015.0016.0018.0019.0019c.0022.0023-on7` | the P5 close-out onezone row above | `REGISTERED_BOOT_IDEMPOTENCE`, `F12_HOSTS_FIX`, `NODE_DOWN_GUARD`, `REJOIN_NODES`, `DURABLE_CM_BARRIER`, `CHASH_ACCESSOR_GUARD` (`OZ_DOMAIN_BOOT_DERIVE` not applicable) | `DISTERL_TLS`, `RTRANSFER_CA_FILTER`, `HELPER_CACHE_REVALIDATE` | `sha256:c6d5df78f0e7…` | `sha256:3b892c361f3144252bce7bb62c9934bc8a497b82186eec6cbadd4ef5bcd6f01f` | Same verification method, oz_panel beam: `REGISTERED_BOOT_IDEMPOTENCE="true"`, `F12_HOSTS_FIX="true"`, `REJOIN_NODES="true"`, all others `false`. `/etc/default/{oz_worker,cluster_manager}` verified. |

**Re-pinned into `sv-federation/v1`** (`crs/oneprovider-b.yaml` only -- provider-a and onezone
stay on their existing images per isolation requirement) as the P5 close-out gate. Operator
image `harbor.k8s-one-onedata.dedyn.io:30003/dev/onedata-operator:v0.6.5-p5` (master `e11f14b`,
digest `sha256:3be1dcfbb0673e016940ad7248e58f680c57af1be0bc4957d4aca58857f6d064`, also pushed to
`docker.io/groundnuty/onedata-operator:v0.6.5-p5`) re-pinned in the same landscape's operator
deployment.
