# cert-manager-desec -- real Let's Encrypt TLS via DNS-01, no internet exposure

Realizes design it.185's containerd-trust dissolution + the
maintainer's deSEC decision: a free `<name>.dedyn.io` subdomain
(deSEC's dynamic-DNS service), cert-manager DNS-01 through a deSEC
webhook solver, and a genuine, publicly-trusted Let's Encrypt
certificate on the PRIVATE Harbor -- **without exposing anything to
the internet**. DNS-01 proves domain control by publishing a TXT
record on deSEC's public nameservers; the cluster itself never accepts
an inbound connection from Let's Encrypt (that's HTTP-01, which this
setup deliberately avoids).

**Why this dissolves the it.185 known gap:** the old
insecure-registry story existed because Harbor's endpoint was
plaintext HTTP -- every client (large-dev's dockerd, and potentially
all 22 nodes' k3s containerd) needed explicit "trust this insecure
host" surgery. A Let's Encrypt certificate chains to roots (ISRG Root
X1/X2) that ship in every stock CA bundle -- containerd on all 22
nodes and large-dev's docker daemon trust it NATIVELY, zero per-node
configuration. The entire gap wasn't patched; the reason it existed
was removed. See `platform/harbor/README.md`'s "Exposure and TLS (v2)".

## What deploys here (one Argo app, `applications/platform/cert-manager-desec.yaml`)

- **`vendor/cert-manager-desec-webhook-v1.0.1-rendered.yaml`** (wave 0)
  -- the vendored webhook solver: Deployment + Service + RBAC +
  `APIService v1alpha1.acme.onedata-gitops-landscapes.internal` + its
  own self-signed serving-cert PKI (an Issuer/Certificate pair scoped
  to webhook-serving TLS only -- unrelated to the Let's Encrypt story,
  it's how cert-manager talks to the solver over the aggregated API).
  Deploys INTO the pre-existing `cert-manager` namespace (this repo
  does not own cert-manager itself -- k8s-one has run v1.21.0 since
  before this repo existed).
- **`cluster-issuers.yaml`** (wave 1) -- `letsencrypt-dns01` (prod) +
  `letsencrypt-staging-dns01` (staging). **Staging-first, always** --
  the full procedure is in that file's header comment.
- **NOT deployed from git: the `desec-token` Secret** -- see "Token
  handling" below.

## Webhook solver chosen: su541/cert-manager-desec-webhook v1.0.1

Five candidates existed on GitHub at build time (all forks of
cert-manager's `webhook-example` scaffold). Survey results
(GitHub API, 2026-07-18):

| repo | last push | releases | verdict |
|---|---|---|---|
| **su541/cert-manager-desec-webhook** | **2026-04-22** | **v1.0.1** | **CHOSEN** -- only actively-maintained one; Helm chart in-tree; declares cert-manager >= 1.15.1, k8s >= 1.25; builds on the well-maintained `nrdcg/desec` v0.8.0 API client |
| kmorning/cert-manager-webhook-desec | 2022-11 | none | stale 3.5y; no releases; Helm section is a literal "TODO" |
| irreleph4nt/cert-manager-webhook-desec-http | 2024-08 | v1.0.1 (2023) | stale 2y |
| nils-bauer/cert-manager-webhook-desec | 2020-03 | none | ARCHIVED |
| kbvepby/cert-manager-webhook-desec | 2021-02 | none | dead fork of kmorning |

**cert-manager compat:** k8s-one runs cert-manager **v1.21.0**
(read-only check of the cert-manager namespace's Deployment images).
The solver is built against the cert-manager v1.15.4 webhook framework
-- the ACME webhook solver contract (aggregated `v1alpha1` API,
`Present`/`CleanUp` verbs) has been stable across every cert-manager
1.x release, and the chart's floor is "cert-manager >= 1.15.1", so
1.21.0 is comfortably in range. K8s floor 1.25 vs. our 1.36: fine
(client-go v0.30, flowcontrol v1 -- both current on 1.36).

**Vendored, not Helm-sourced** -- same call, same reasons as
`platform/harbor/README.md`'s "helm-vendored vs. Argo Helm source"
(and this chart isn't even published to a chart registry -- upstream's
own install instruction is `helm install` from a local checkout, so
vendoring the render is the only network-free option anyway).

**Two honest caveats from source inspection** (flagged, accepted):
`Present()` calls deSEC's RRset *Create* -- if a stale
`_acme-challenge` TXT RRset survives a crashed cleanup, the next
issuance fails until it's deleted (visible in the Challenge's status
message; `curl -X DELETE .../rrsets/_acme-challenge.harbor/TXT/` or
the deSEC web UI clears it). And its error paths use `klog.Fatal`,
which exits the webhook pod -- ugly but self-healing (the Deployment
restarts it). Neither disqualifies it against four unmaintained
alternatives.

**Image tag pinned to `v1.0.0`, chart templates from git tag
`v1.0.1`:** ghcr.io has image tags {v1.0.0, master, latest, nightly}
but no v1.0.1 -- verified against ghcr's tags/list API at build time;
upstream's release CI evidently never pushed the matching image tag.
v1.0.0 is the newest immutable image; the v1.0.0->v1.0.1 source diff
is dependency bumps only.

## dedyn.io is on the Public Suffix List (verified)

Checked directly against the authoritative
`publicsuffix/list/public_suffix_list.dat` on 2026-07-18: `dedyn.io`
is listed (submitted by deSEC themselves). Two consequences, both
good:

1. **Own Let's Encrypt rate-limit bucket.** LE's "certificates per
   registered domain" limit counts PSL-registered domains --
   `<name>.dedyn.io` is its own registered domain, so this cluster
   competes with nobody else on dedyn.io for the 50/week budget.
2. **No PSL-related issuance problem for cert-manager.** Some ACME
   clients (lego-based ones, e.g. the Home Assistant deSEC add-on)
   mis-derive the zone for multi-label dedyn.io names from the PSL.
   cert-manager derives `ResolvedZone` by live SOA lookup (finds
   `<name>.dedyn.io`'s own SOA on deSEC's nameservers), and this
   webhook then matches against the token's actual domain list via the
   deSEC API -- no PSL parsing anywhere in the path.

## Token handling (the one real credential -- NEVER in git)

The deSEC API token grants write access to a real, internet-facing DNS
zone -- and DNS control is certificate-issuance control. It is the
explicit EXCEPTION to this repo's plaintext-demo-secrets convention:

- `desec-token.placeholder.yaml` documents the Secret's shape; it is
  NOT in `kustomization.yaml`, never synced, and contains an obvious
  `REPLACE_ME`.
- `make desec-token TOKEN=<real-token>` creates/updates the Secret
  directly on the cluster (`kubectl ... | kubectl apply`), bypassing
  git entirely. `DESEC_TOKEN=<real-token> make desec-token` does the
  same without putting the token on the make command line (shell
  history).
- `.gitignore` catches `desec-token.real.yaml` / `*.real.yaml` if a
  real manifest is ever materialized locally.
- The webhook's RBAC Role is scoped by `resourceNames` to exactly this
  one Secret in exactly the `cert-manager` namespace.

Scope discipline on the deSEC side: create the token with **only** the
`<name>.dedyn.io` domain policy if using deSEC's token policies --
this repo's automation never needs account-level rights.

## The A record: `make dns-record`, not external-dns

Harbor needs `harbor.<name>.dedyn.io` to resolve to a node IP
(private, 10.87.x -- publishing a private IP in public DNS is fine and
deliberate here: the name is only reachable from the LAN/VPN, which is
the "no internet exposure" point). That is ONE static A record, so v1
is a one-shot idempotent `make dns-record` target: a `curl -X PATCH`
of the deSEC rrsets bulk API (`PATCH /api/v1/domains/<name>.dedyn.io/rrsets/`
with `[{subname: harbor, type: A, ttl: 3600, records: [<node-ip>]}]`)
-- PATCH creates-or-updates atomically and re-runs are no-ops. TTL
3600 is deSEC's minimum.

**external-dns verdict (checked 2026-07-18):** a community webhook
provider for deSEC exists (`michelangelomo/external-dns-desec-provider`,
last push 2026-07; plus the `sshine/` bugfix fork, 2026-06) and is the
named upgrade path if this repo ever manages more than a handful of
records -- but running a whole controller to reconcile one static A
record is overkill, and external-dns's maintainers explicitly don't
review/vouch for webhook providers. Not built here.

The wave-0 slot for DNS is therefore OUTSIDE Argo: token ->
`make dns-record` -> this app -> harbor (see the top-level README's
Harbor deploy order).

## groupName

`acme.onedata-gitops-landscapes.internal` -- the aggregated-API group
the webhook registers (`APIService v1alpha1.<groupName>`). It is an
identifier, not a resolvable domain; it appears in exactly two places
that must agree: `values.yaml` (baked into the vendored render) and
`cluster-issuers.yaml`'s `solvers[].dns01.webhook.groupName`.

## Regenerating the vendored render

See the vendored file's own header for the exact command (helm
template from a local checkout of the upstream repo at git tag v1.0.1,
`--namespace cert-manager`, `-f values.yaml`, then the yq sync-wave-0
stamp -- same pipeline as platform/harbor's vendor file).

## Known gaps / residual honesty

- **The A record is one node IP** -- if that node dies, the name goes
  dark until `make dns-record HARBOR_NODE_IP=<other-node>` re-points
  it (any of the 22 works; TTL 3600 bounds the stale window). A
  keepalived-style VIP or a multi-A-record set is the obvious v2 if
  this ever matters.
- **In-cluster DNS dependency:** pods resolving `harbor.<name>.dedyn.io`
  ride CoreDNS's upstream forwarding to public resolvers. k3s's
  default CoreDNS does this out of the box; a resolver that filters
  RFC1918 answers from public zones (DNS-rebind protection) would
  break it -- k8s-one's does not, noted in case that ever changes.
- **Wildcard later:** DNS-01 is the only ACME challenge type that can
  issue wildcards -- a `*.<name>.dedyn.io` Certificate through this
  same issuer would cover the Argo CD UI and any future platform app
  in one cert. Mentioned, not built (Argo CD stays port-forward-only
  by design today).
