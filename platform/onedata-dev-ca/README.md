# onedata-dev-ca -- cluster-singleton shared development CA

Realizes design it.194 (the maintainer's dev-CA question), it.195 (the
verdict: issuing is already generic, trust-distribution was gapped),
it.196 (green-lit, split build), it.200 (the operator-side half --
`spec.tls.trustIssuerCA` -- MERGED), and it.203 (Harbor-for-everything;
this platform app + Harbor-image integration together make
`sv-posix-multinode/v2` "the reproducible-from-git productionized
landscape"). Full design writeup:
`research/dev-ca-trust-design.md`.

## What this is

A cluster-scoped CA `ClusterIssuer` named `onedata-dev-ca`, built from
cert-manager's own standard in-cluster-PKI bootstrap
(`ca-issuer-chain.yaml`):

```
SelfSigned Issuer  --signs-->  CA Certificate (onedata-dev-ca, in cert-manager ns)
                                     |  secretName: onedata-dev-ca
                                     v
                               CA ClusterIssuer (onedata-dev-ca)  --signs-->  every landscape's leaf certs
```

Every dev landscape's managed Onezone/Oneprovider CRs point their own
`spec.tls.issuerRef` at it and set `spec.tls.trustIssuerCA: true`:

```yaml
spec:
  tls:
    issuerRef:
      name: onedata-dev-ca
      kind: ClusterIssuer
    trustIssuerCA: true
```

`trustIssuerCA` (it.200, operator master `b406b86`) is what makes this
actually WORK end-to-end for a private CA, not just issue certificates
nobody trusts: it tells the operator to mount the issued Secret's
`ca.crt` into every component's `cacerts_dir`
(`/etc/{op,oz}_worker/cacerts/`, `/etc/{op,oz}_panel/cacerts/`) --
closing the trust-distribution gap `research/dev-ca-trust-design.md`
identified (issuing alone was already generic via the cert-MVP's
issuer-agnostic `issuerRef`; only the *trust* half was gapped, and only
for a private/dev CA -- a public ACME/LE cert never needed this because
its roots already live in the base image's public trust store).

## Why this exists instead of always using Let's Encrypt

See `research/dev-ca-trust-design.md` S5 for the full comparison; the
short version:

| | **Dev CA (this app)** | **Let's Encrypt (`letsencrypt-dns01`)** |
|---|---|---|
| Rate limits | none | LE per-domain/duplicate-cert limits |
| External dependency | none (in-cluster) | public DNS + DNS-01 solver |
| Works on minikube / air-gapped | yes | no |
| Issuance latency | instant | seconds-minutes (DNS-01 propagation) |
| Browser-trusted | no | yes |

Dev/test landscapes optimize for self-containment -> dev-CA is the
right default for landscape-internal component TLS (GraphSync,
rtransfer, onepanel<->zone, oneclient<->provider). **Reserve
`letsencrypt-dns01` for endpoints that genuinely need a
browser-trusted public name** -- Harbor's registry
(`platform/harbor/`, already wired it.185/186) is the only such
endpoint in this repo today.

## Why deploy into the pre-existing `cert-manager` namespace

Same reasoning as `platform/cert-manager-desec/`: a `ClusterIssuer`'s
`secretName` Secret is looked up in cert-manager's
**cluster-resource-namespace** (default = the `cert-manager` namespace
cert-manager itself runs in). This platform app's CA Certificate and
its bootstrap self-signed Issuer both carry an explicit
`metadata.namespace: cert-manager` for exactly this reason -- there is
no dedicated `onedata-gitops-onedata-dev-ca` namespace, unlike Harbor
(which runs real workload pods and legitimately needs its own).

## Why a THIRD ClusterIssuer

k8s-one already has `cluster-ca`/`selfsigned` ClusterIssuers (per the
it.194/195 recon) and, since `platform/cert-manager-desec/`,
`letsencrypt-dns01`/`letsencrypt-staging-dns01`. A purpose-scoped,
onedata-gitops-landscapes-owned CA is cleaner to reason about, rotate
independently, and hand to trust-manager later (the it.195 "Option B"
upgrade, not built here) than reusing a pre-existing general-purpose
cluster CA this repo does not otherwise own or version.

## Rotation (honest gap, not built here)

The CA Certificate is long-lived (10y, `duration: 87600h`) precisely
because rotating it is NOT rotation-safe in this MVP shape: a single
`ca.crt` file mount (the it.200 `trustIssuerCA` mechanism) has no
old+new overlap window the way a `trust-manager` `Bundle` would (see
`research/dev-ca-trust-design.md`'s "Option B"). If this CA is ever
rotated, every landscape's already-running pods need their
`trustIssuerCA` mount refreshed (a pod restart picks up the new
`ca.crt` subPath once the underlying Secret updates) roughly in lock
step, or peer TLS breaks during the overlap. Flagged here, not solved
-- the documented upgrade path is trust-manager's `Bundle` CR, which
can carry old+new CA simultaneously.

## Deploy

Independent of the mandatory landscape sequence -- only needs Argo CD
to already exist (same posture as Harbor/cert-manager-desec):

```sh
make argocd-install     # if not already done
make dev-ca-deploy      # apply this platform Application
```

**GATED, same as every landscape and platform app in this repo:**
schema-valid and dry-run-clean (`make validate`), NOT yet applied to
k8s-one as of this build.

## Known gaps (documented, not hidden)

- **No rotation story beyond a 10y root + manual re-key** -- see
  "Rotation" above; trust-manager is the documented, not-built,
  upgrade.
- **Not browser-trusted** -- by design; nothing in this repo expects a
  browser to trust `onedata-dev-ca` (a landscape's own GUI endpoints
  using this CA will show a browser warning, same as any dev CA;
  cosmetic and orthogonal to the transport-TLS problem this app
  solves -- see `research/dev-ca-trust-design.md` S6's blast-radius
  table).
- **One CA for every dev landscape.** A landscape wanting an isolated
  CA of its own (rather than sharing this cluster singleton) would need
  its own `Issuer`/`Certificate`/`ClusterIssuer` chain, landscape-side
  -- not what any landscape in this repo does today (all of them, if
  they opt into dev-CA TLS, share this one `onedata-dev-ca`
  ClusterIssuer).
