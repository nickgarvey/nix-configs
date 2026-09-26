# How TLS works in this homelab

Every certificate a client on this network verifies is publicly trusted. There is no
private CA any more (see [Retired: the Garvey Home CA](#retired-the-garvey-home-ca)); the
only self-signed material left is Kubernetes' internal PKI, which never leaves the cluster.

Configuration is split across two repos, so paths below are prefixed when ambiguous:
this repo (`nix-configs/`) owns the router, DNS, and host-level pieces; `k8s-gitops/`
owns cert-manager, acme-dns, and the services themselves.

---

## The three ways a cert gets issued

| Path | Names | Issued by | Config |
|---|---|---|---|
| cert-manager + acme-dns | `*.garvey.sh` | Let's Encrypt, DNS-01 | `k8s-gitops/manifests/cert-manager/cluster-issuer-acmedns-{prod,staging}.yaml` |
| On-box ACME | `homeassistant.home.garvey.sh`, `garage.home.garvey.sh`, `storj-gateway.home.garvey.sh`, `rgw.home.garvey.sh` | Let's Encrypt, DNS-01 via RFC2136 | HAOS itself / `security.acme` on lydia + wabbajack / `security.acme` on dragonsreach / `security.acme` on joor + zah + frul (Ceph RGW); TSIG ACLs in `modules/containers/knot-auth.nix` |
| Tailscale | `*.bigeye-turtle.ts.net` | Tailscale | `ingressClassName: tailscale` on the Ingress |

Kubernetes' own internal PKI (apiserver, kubelet, etcd, Cilium) is separate from all of
this — k3s manages it, nothing here touches it, and it never appears on the LAN.

### 1. cert-manager via acme-dns — the default for public names

This is how `oci.garvey.sh`, `jellyfin.garvey.sh`, and `temporal.garvey.sh` get their certs.
Since the Cloudflare issuer was retired (2026-08-10) it is the **only** in-cluster path —
every `Certificate` uses `letsencrypt-acmedns-prod`.

acme-dns (`acme.garvey.sh`) holds **one account per hostname**. Each account can only
write the TXT record under its own random subdomain, so a leaked account cannot touch any
other name. A `_acme-challenge.<host>` CNAME in Cloudflare points at that random
subdomain, which is what makes Let's Encrypt's DNS-01 lookup land somewhere the account is
allowed to write.

The point of the indirection: **no Cloudflare credential exists in the cluster at all**, and
no zone edits happen at renewal time. The one-time CNAME is the only Cloudflare change, made
by hand with an operator-supplied token.

Two consequences worth internalising:

- **The cert is decoupled from where the service points.** DNS-01 proves control via
  `acme.garvey.sh`, not via `<host>`'s address. You can issue a cert before the service
  exists, and changing a service's IP never affects issuance.
- **Registration is currently open** (`disable_registration = false`). That is deliberate,
  to avoid a toggle dance during onboarding, but it is known security debt — the API is
  ClusterIP-only and `allowfrom` restricts `/update` to the cluster pod CIDR, which is what
  makes it tolerable.

Full step-by-step onboarding, including the gotchas that can orphan an account, is in
`k8s-gitops/manifests/acme-dns/ONBOARDING.md`. Don't improvise it — acme-dns has no
lookup-by-name, so a lost registration response is unrecoverable.

### 2. On-box ACME against our own Knot

For the things cert-manager cannot deliver a cert to — Home Assistant, which runs HAOS
rather than NixOS, and the two S3 endpoints, which run in nspawn containers (garage on
lydia and wabbajack, the Storj gateway on dragonsreach) — the box issues its own cert with
DNS-01 by **RFC2136 dynamic update against our own Knot**.

The interesting part is the ACLs in `modules/containers/knot-auth.nix`. Every TSIG key
handed out is scoped to a single owner name and a single record type:

```
update-owner-name = [ "_acme-challenge.homeassistant.home.garvey.sh." ]
update-type       = [ "TXT" ]
```

So compromising a box that holds one cannot repoint any real record in the zone — it can
only write TXT at that one challenge name. That scoping is what makes on-box issuance an
acceptable substitute for routing these through acme-dns. It is also why the `acme-garage`
key can be shared by *every* garage node: the ACL is scoped to the one name they all write,
not to a host, so adding a node is a new recipient on `secrets/garage-acme.yaml` and
nothing else.

Knot's zone is loaded from the Nix store and never written back
(`zonefile-sync = -1`), so the zone stays reproducible in git while still accepting these
dynamic TXT updates — `zonefile-load = "difference"` plus `journal-content = "changes"` is
what keeps an in-flight challenge from being wiped by an unrelated config reload.

**Garage's shape is worth knowing**, because the cert is issued on one machine and used on
another. Garage speaks no TLS itself, so nginx inside the container terminates it and
proxies to garage on the loopback; the container has no route to the internet
(`modules/containers/common.nix` gives it no IPv6 default route and no IPv4 at all), so
lego runs on the *host* and `/var/lib/acme/garage.home.garvey.sh` is bind-mounted in.
nginx reads its cert at startup, so the renewal hook is a `systemctl -M garage restart
nginx.service` from the host's acme unit.

Two consequences: **each node issues its own copy** of the same name, so a cluster-wide
first issuance spends one of Let's Encrypt's 5-per-week duplicate certificates per node
(renewals stagger themselves and come nowhere near it); and **port 3900 stays plaintext**,
so a failed cert degrades to what garage did before rather than taking the service down.
Consumers move to `https://garage.home.garvey.sh` one at a time.

**The Storj gateway's shape is different, and the difference is instructive.** gateway-st
embeds minio, which reads its own certificate from `<config-dir>/certs/{public.crt,
private.key}` — `main.go` passes `--config-dir` and no `--certs-dir`, so the certs
directory falls out of the config directory. There is no proxy: an import unit inside the
container copies the host-issued pair into `/var/lib/storj-gateway/minio/certs` under the
names minio expects, and the renewal hook restarts the gateway.

**The degradation is not symmetric, and that bit us.** minio serves plain HTTP when it
finds *no* certificate, but a certificate it cannot load is fatal — it aborts at startup.
`security.acme` always plants a minica self-signed placeholder before the first successful
order, and minica issues P-384, which minio rejects outright (Go has no constant-time
P-384; `storj.io/minio` `cmd/config/certs.go:102`). So a first order that fails does not
leave the gateway on HTTP — it leaves it crash-looping. The import unit therefore checks
the key's curve and declines to install anything minio would refuse, which is what makes
the "falls back to HTTP" claim actually true.

The cost is that minio has exactly one listener, so **port 7777 converts** rather than
gaining a sibling: there is no plaintext port left to migrate consumers off gradually. That
was affordable here because Mimir is the only consumer. Prefer garage's shape when a
service has several.

One more local quirk: dragonsreach runs both lego *and* the Knot it updates, so a rebuild
restarts them together. An order that starts before knot-auth is listening dies with a
socket-level refusal — `could not find the start of authority ... connection refused` —
and spends a Let's Encrypt failed-validation slot. The order unit waits for the zone's SOA
to be answered before running. The garage nodes need no such wait: they query Knot across
the LAN, where it is already up.

**`dnsPropagationCheck = false` is load-bearing, not a shortcut.** lego's default
propagation check ignores `dnsResolver`: it looks up the zone's NS (`ns1` → our WAN
address) and queries *that*. From the LAN the `:53` DNAT does not apply — it matches on the
WAN interface — so the query lands on blocky rather than dnsdist, and blocky's 1m negative
cache (`modules/router/blocky-dns.nix`) outlives lego's 60s propagation timeout. This is
the same hairpin dead end `modules/router/knot-resolver.nix` documents for
`acme.garvey.sh`, and it fails *intermittently*: one node can win the race against the
cache entry while the other times out with

```
propagation: time limit exceeded: last error: authoritative nameservers:
NS ns1.home.garvey.sh.:53 returned REFUSED for _acme-challenge.garage.home.garvey.sh.
```

Nothing is lost by disabling it. Knot is the only authoritative server and its DDNS update
is committed before lego proceeds, so there is no propagation to await; Let's Encrypt
validates from the public internet, where the DNAT does apply. Any future on-box ACME
client on this network needs the same setting.

### 3. Tailscale Ingress

The default for HTTP UIs that don't need a public name: `couchdb`,
`authentik`, `grafana`, and jellyfin's UI. Tailscale terminates TLS with its own cert for
`*.bigeye-turtle.ts.net` and the name is tailnet-only. Nothing in this repo manages those
certs.

---

## How TLS is terminated

**Services that serve TLS terminate it themselves, on port 443 directly** — not on a high
port behind a LoadBalancer port map. `zot` and `jellyfin` both do this: the cert-manager
Secret is mounted into the pod and the app reads it.

```yaml
# k8s-gitops/manifests/zot/configmap.yaml
"port": "443",
"tls": { "cert": "/etc/zot/tls/tls.crt", "key": "/etc/zot/tls/tls.key" }
```

Keeping the listener on 443 means the public URL needs no port suffix and the LB mapping
stays a straight 443→443, which is one less thing to get wrong when a service also has a
Tailscale Ingress in front of a different port.

## Split-horizon DNS keeps the cert name honest

A public name like `jellyfin.garvey.sh` resolves publicly to the WAN address. From inside
the LAN, hairpinning out and back would be wasteful — but simply pointing clients at the
internal IP would break TLS, because the cert is for the public name.

The fix is in `modules/networking/dns.nix`:

```nix
garveyShOverrides = {
  "oci.garvey.sh"      = "2001:470:482f:2::5000";
  "jellyfin.garvey.sh" = "2001:470:482f:2::5001";
};
```

blocky serves these from `customDNS`, so LAN clients reach the LoadBalancer directly **and
still verify against the public name**. Add any future public-named service here.

---

## The fragile part: WAN IP → DNS-01 → renewals

This is the failure mode most worth understanding, because it is silent.

Every DNS-01 renewal requires Let's Encrypt to reach our authoritative DNS from the public
internet — `ns1.home.garvey.sh` for the Knot zone, and the `acme.garvey.sh` delegation.
Both publish our **DHCP-assigned WAN address**, hardcoded in Cloudflare glue and in
`modules/networking/zone.nix`, with **no DDNS automation**.

When that address drifts, renewals begin failing immediately, and nothing else notices for
weeks — until certificates approach expiry. So there are two layers of alerting:

- **Early warning:** `modules/router/wan-dns-drift.nix` resolves our published records
  through a public resolver and compares them to the WAN interface's actual address.
  `PublishedWanIPDrift` fires within 15 minutes
  (`k8s-gitops/manifests/prometheus/rules/wan-dns.yaml`).
- **Backstop:** the cert-manager rules in
  `k8s-gitops/manifests/prometheus/rules/certificates.yaml` — not-Ready for an hour,
  under 21 days remaining (cert-manager renews at 30, so this means a renewal already
  failed), and under 7 days as critical. `CertManagerMetricsMissing` covers the case where
  cert-manager itself is down, which would otherwise look identical to "no problems".

If drift happens, fix it in three places: Cloudflare glue for `home.garvey.sh`, Cloudflare
glue for `acme.garvey.sh`, and `ns1` in `modules/networking/zone.nix`.

### Home Assistant needs its own probe

cert-manager has no visibility into HA's on-box cert, and expiry alone would not catch the
real failure mode: **HA only loads its certificate at startup**, so a renewal that isn't
followed by a restart leaves it serving the old one indefinitely.

`modules/services/ha-cert-probe.nix` (runs on fus) therefore checks what HA actually serves
on the wire, asserting hostname match *and* chain validity against the system trust store —
not just remaining lifetime:

```
openssl s_client -connect homeassistant.home.garvey.sh:8123 \
  -verify_hostname homeassistant.home.garvey.sh -verify_return_error
```

This is also the canary for trust-store changes on NixOS hosts: it is the one check that
would notice if something still depended on a CA we removed.

---

## Retired: the Garvey Home CA

A private CA (`Garvey Home Root CA` → `Garvey Home Intermediate CA`, hand-issued via XCA in
March 2024) used to sign internal services. It was **fully retired in August 2026** once
Home Assistant — its last real consumer — migrated to on-box Let's Encrypt.

Removed at that time:

- `public_certs/` and the `security.pki.certificateFiles` entry in
  `modules/core/nixos-common.nix` that installed it into every NixOS host's trust store
- `k8s-gitops/garvey-ca.pem`, orphaned since the n8n deployment was deleted
- The `trmnl-display-ca` ConfigMap and its volume mount

Verified before removal: no endpoint on the LAN serves a cert chaining to it (probed all
hosts in `modules/networking/lan-hosts.nix` across the common TLS ports), and no
cert-manager Issuer is a `ca` or `selfSigned` issuer.

**If you ever need it back**, both certs are recoverable from git history, and the private
key lives in XCA outside these repos.

### Leftovers that are harmless but stale

- `modules/k3s/k3s-common.nix` still passes `--tls-san=k3s-api.home.arpa`, a name from the
  retired `home.arpa` zone. Harmless (it is an extra SAN on an internal cert nothing
  validates by that name), but misleading.

---

## Adding a new public service: the short version

This is the in-cluster path. A service on a NixOS host instead takes path 2 above: add a
TSIG identity to `acmeKeys` in `modules/containers/knot-auth.nix`, a sops file holding the
key encrypted to both dragonsreach and the host, and `security.acme` with
`dnsProvider = "rfc2136"` — see `modules/containers/garage.nix` for a worked example.

1. Register an acme-dns account and add the `_acme-challenge` CNAME in Cloudflare —
   follow `k8s-gitops/manifests/acme-dns/ONBOARDING.md` exactly.
2. Add a `Certificate` with `issuerRef: letsencrypt-acmedns-prod`. Validate against
   `letsencrypt-acmedns-staging` first if the name is at all unusual; Let's Encrypt's prod
   rate limits are unforgiving.
3. Mount the resulting Secret in the pod and terminate TLS on **443**.
4. Add the name to `garveyShOverrides` in `modules/networking/dns.nix` so LAN clients get
   the internal address without breaking verification.
5. Confirm `certmanager_certificate_ready_status` goes to 1 — the alerts above will
   otherwise tell you about it an hour later.

**Note that a LoadBalancer Service publishes its name and address publicly.** The
`home.garvey.sh` zone is delegated from Cloudflare and resolves from the open internet, so
`<svc>.<ns>.k8s.home.garvey.sh` is enumerable by anyone. Resolvable is not reachable —
inbound IPv6 is default-deny at the router — but don't treat an internal address as secret.
