# `sv-posix-multinode` / `v2`

The **reproducible-from-git productionized successor** to
[`v1`](../v1/README.md) (design it.196/203) -- SAME feature under test
(the it.161/164 multi-worker shared-RWX-posix pattern v1 already proved
live on real hardware, design it.198), but with the drive-first/dev-only
rough edges v1 carried closed out:

| | v1 | v2 |
|---|---|---|
| TLS | operator default self-signed + a separate, UNWIRED self-signed Issuer+Certificate (honest gap) | `spec.tls.issuerRef` -> the shared `onedata-dev-ca` ClusterIssuer, **`trustIssuerCA` REMOVED** (design it.194-196/200 introduced it; it.238/Finding 11 removed it again -- crashes a managed Oneprovider's `rtransfer_link`, core-side bug, no operator-side fix possible until patch 0013 lands in a deployed image; see `crs/oneprovider.yaml`'s header) |
| Operator image | `groundnuty/onedata-operator:v0.6.0` (public Docker Hub) | `harbor.k8s-one-onedata.dedyn.io:30003/dev/onedata-operator:v0.6.3` (Harbor's private `dev` project, design it.203; bumped from v0.6.1 by the it.230/it.238 sweep) |
| Onezone/Oneprovider images | `docker.onedata.org/{onezone,oneprovider}-dev:develop` (private registry + external `docker-onedata-org` imagePullSecret) | `harbor.k8s-one-onedata.dedyn.io:30003/dockerhub-proxy/onedata/{onezone,oneprovider}:21.02.7` (Harbor's public proxy-cache of a PUBLIC Docker Hub image; no imagePullSecret needed for these two -- noted as a release-tag re-pin candidate in `images/SNAPSHOTS.md`, not yet digest-pinned) |
| NetworkPolicy | additive landscape-side Couchbase-ports shim (`crs/networkpolicy-couchbase.yaml`, working around an operator-chart defect) | GONE -- the chart's own it.201 fix + it.202's NetworkPolicy-default-OFF flip (v0.6.1 onward) make the shim unnecessary |
| Namespace | `sv-posix-multinode` (RUNNING, left untouched) | `sv-posix-multinode-v2` (separate; does not collide with v1) |

Deliberately deployed **alongside** v1, not in place of it -- v1 stays
running in its own namespace for as long as the maintainer wants it.

**Status as of the it.230/it.238 re-pin:** v2 was deployed once (proving
dev-CA TLS trust, Harbor-pull, and the multi-node RWX/CDMI payoff --
`research/gitops-v2-deploy.md`), then deliberately TORN DOWN
(disk-pressure capacity decision, unrelated to this sweep) and has not
been redeployed since. The operator-image bump to v0.6.3 and the
Finding-11 `trustIssuerCA` removal below are therefore purely git-side
-- redeploying from git is exactly the reproducible-from-git property
this landscape exists to prove.

## Sync waves

```
wave -1   00-namespace.yaml            the sv-posix-multinode-v2 namespace
wave  1   operator/                    namespace-scoped onedata-operator, --watch-namespace=sv-posix-multinode-v2
wave  2   crs/                         demo Secrets, the storageVolume PVC, Onezone, Oneprovider
```

No wave-0 cert-config slot (unlike v1) -- see `kustomization.yaml`'s
header comment for why: TLS is now driven directly by each managed
CR's own `spec.tls`, consumed by the operator's cert-MVP at CR-apply
time (wave 2), closing v1's "issued but unwired" honest gap via the
real path instead of carrying a dead placeholder forward.

## Image pins

1. **`harbor.k8s-one-onedata.dedyn.io:30003/dev/onedata-operator:v0.6.3`**
   (`operator/deployment.yaml`). The original scaffold's v0.6.1 forward
   reference shipped and was live-deployed; the it.230/it.238
   upstream-image-snapshot sweep bumped the pin to v0.6.3, which
   carries forward v0.6.1's it.200 `trustIssuerCA` mount, it.201
   disterl-NetworkPolicy Couchbase-ports fix, it.202
   NetworkPolicy-default-OFF flip, and onepanel bootstrap-task retry
   heal, plus v0.6.2/v0.6.3's GS-check + dual-binding truthful-status
   work (design log it.233/it.235/it.237) on top. Also pushed to Docker
   Hub as `groundnuty/onedata-operator:v0.6.3` per it.203's directive
   (this landscape pins the Harbor ref by policy choice, not necessity
   -- see the top-level README's Harbor section). Before this bump
   reaches a live cluster, (re-)run
   `make harbor-pull-secret NS=sv-posix-multinode-v2`.

2. **The `onedata-dev-ca` ClusterIssuer** (`platform/onedata-dev-ca/`,
   referenced by both `crs/onezone.yaml` and `crs/oneprovider.yaml`'s
   `spec.tls.issuerRef`) must be synced and its `ClusterIssuer` `Ready`
   BEFORE this landscape's wave-2 CRs sync -- otherwise the operator's
   cert-MVP will fail to obtain a certificate (the `Certificate` object
   it creates will sit at `Ready=False`, referencing a
   nonexistent/not-yet-Ready issuer) and both Onezone and Oneprovider
   will stall waiting on their web certificate.

Verified fact this landscape RELIES on but did not itself introduce:
`onedata/oneprovider:21.02.7` and `onedata/onezone:21.02.7` ARE already
public on Docker Hub today (checked 2026-07-18 via the Docker Hub v2
tags API) -- only the Harbor `dockerhub-proxy` proxy-cache PATH to them
is new here, not the underlying images.

## Gated deploy order (all of this is EXTERNAL to this build; nothing here was applied to k8s-one)

```
# Prerequisites already on k8s-one as of this build (from the v1 first
# deploy, research/gitops-first-deploy.md): scope-cluster-manager,
# apply-crds, argocd-install. crds/ was BUMPED by this same change (see
# the top-level crds/README.md's superset rule) to pick up
# spec.tls.trustIssuerCA -- re-run `make apply-crds` before deploying
# v2, even though steps 1-3 already ran for v1.

make apply-crds                                     # re-run: picks up trustIssuerCA (+ growMode etc.) in the CRD superset

# Dev-CA platform app (independent of Harbor; only needs argocd-install)
make dev-ca-deploy
# ... wait for the onedata-dev-ca ClusterIssuer to report Ready ...

# Harbor must already be deployed + configured (v1's own prerequisite
# chain -- set-harbor-domain, desec-token, dns-record,
# certmanager-desec-deploy, harbor-deploy, harbor-configure) and
# groundnuty/onedata-operator:v0.6.3 must be pushed into its `dev`
# project (see "Image pins" above) BEFORE the next two steps:
make harbor-pull-secret NS=sv-posix-multinode-v2     # the operator image pull secret (private `dev` project)

make deploy-landscape NAME=sv-posix-multinode VERSION=v2
# ... wait for onezone/zone and oneprovider/provider to report Ready ...

NAMESPACE=sv-posix-multinode-v2 ./apply-dependent-crs.sh
```

**v1 is untouched by any of the above** -- different namespace,
different Application, different operator instance; nothing in this
sequence reads, writes, or deletes anything in the `sv-posix-multinode`
namespace.

## External prerequisites (not created by this repo)

- **`harbor-dev-pull` imagePullSecret**, in the `sv-posix-multinode-v2`
  namespace -- created by `make harbor-pull-secret NS=sv-posix-multinode-v2`
  (needs Harbor's `dev` project + robot credential already configured).
  Referenced by `operator/serviceaccount.yaml`.
- **`groundnuty/onedata-operator` (or the Harbor `dev`-project
  equivalent) `v0.6.3`** pullable -- see "Image pins" above.
- **The `onedata-dev-ca` ClusterIssuer** `Ready` -- see "Image pins"
  above.
- Steps 1-3 of the top-level README's mandatory deploy sequence
  already applied (shared with v1; not repeated per-landscape).

**Dropped versus v1:** the external `docker-onedata-org` imagePullSecret
prerequisite is GONE for v2's Onezone/Oneprovider images -- they now
pull from Harbor's PUBLIC `dockerhub-proxy` project, which needs no
credential at all (see `crs/onezone.yaml`'s header comment).

## Known gap: StorageBackend/User/Space/Support are a day-2 step

Identical, unchanged limitation to v1 (and `demo/landscape-3p`/
`demo/landscape-max` in the operator repo) -- see v1's README for the
full source-level rationale. Same script, same procedure, just a
different default namespace:

```sh
NAMESPACE=sv-posix-multinode-v2 ./apply-dependent-crs.sh
```

## Validate (no cluster contact)

```sh
make validate-landscapes   # kustomize build + kubectl create --dry-run=client, this landscape included
NAMESPACE=sv-posix-multinode-v2 APPLY_CMD=cat \
  PROVIDER_ONEPANEL_ENDPOINT=10.0.0.1:9443 ZONE_ONEPANEL_ENDPOINT=10.0.0.2:9443 \
  ./landscapes/sv-posix-multinode/v2/apply-dependent-crs.sh   # renders the day-2 CRs offline
```
