# Architecture

## Layout

```
bootstrap/                       one-time, manually-applied Application (the "root")
clusters/rpi-cluster/
  platform/                      cluster-wide infrastructure Applications
  apps/                          workload Applications, one file per app
apps/<name>/                     the actual Helm chart for each workload (Chart.yaml, values.yaml, templates/)
platform/<component>/            plain CR manifests for a platform Application's chart (see "Adding a platform component")
site/                            source for the resume site image (built by CI, not synced by ArgoCD)
scripts/                         per-node OS prep run before kubeadm (see kubeadm-install-guide.md)
.github/workflows/               image build + digest write-back
docs/                            install guide, explainers, external setup, this file
```

`site/` is the odd one out: it holds the HTML/CSS and Dockerfile that become
the container image, not anything applied to the cluster. ArgoCD's root
Application only watches `clusters/rpi-cluster`, so nothing under `site/` is
ever synced — including the legacy `site/k8s.yaml`, which is superseded by
`apps/resume` and kept only as a plain-manifest reference.

`platform/<component>/` is the newer sibling to `apps/<name>/`: a place for
plain Kubernetes manifests (not a Helm chart) that belong to a platform
Application - CRs like MetalLB's `IPAddressPool` or Envoy
Gateway's `Gateway`. It lives outside `clusters/rpi-cluster` for the same
reason `apps/` does: the root Application's `directory.recurse: true` watches
`clusters/rpi-cluster` and would double-apply anything placed there directly.

## Pattern: app-of-apps

`bootstrap/root-app.yaml` is applied by hand exactly once, against a cluster
that already has ArgoCD running. It points ArgoCD at `clusters/rpi-cluster`
with `directory.recurse: true`, so ArgoCD watches that whole subtree for
`Application` manifests and syncs whatever it finds - both platform
components and workloads - without any further manual `kubectl apply`.

Everything under `clusters/rpi-cluster/{platform,apps}/*.yaml` is an
`Application` resource, not the workload itself. The workload's actual
templates live in `apps/<name>/` as a Helm chart, referenced by
`spec.source.path`. This split keeps "what gets deployed and how it's
configured to sync" (the Application) separate from "what the app actually
is" (the chart).

## Pattern: ArgoCD manages itself

`clusters/rpi-cluster/platform/argocd.yaml` is an `Application` whose source
is the upstream `argo/argo-cd` Helm chart, with values pulled from
`argocd-values.yaml` in this repo via ArgoCD's multi-source `$values` ref.
Once bootstrapped, changes to ArgoCD's own version or configuration go
through the same GitOps loop as everything else - edit
`argocd-values.yaml` or bump `targetRevision`, commit, ArgoCD syncs itself.

The manual bootstrap step installs ArgoCD with the *same* chart and values
file so the self-management Application adopts the existing release cleanly
instead of fighting a differently-configured install.

## What's deployed

| Component | Source | Notes |
| --- | --- | --- |
| ArgoCD | `platform/argocd.yaml` | manages itself |
| Cilium | `platform/cilium.yaml` | CNI only (its LB-IPAM is off); adopted from the kubeadm bootstrap install, manual sync until diff is confirmed empty |
| MetalLB | `platform/metallb.yaml` + `platform/metallb/` | LoadBalancer IPs, L2/ARP mode; needs `ignoreExcludeLB` on this all-control-plane cluster |
| Envoy Gateway | `platform/envoy-gateway.yaml` + `platform/envoy-gateway/` | Gateway API implementation; replaced Traefik |
| local-path-provisioner | `platform/local-path-provisioner.yaml` | dynamic, non-replicated `local-path` StorageClass; stopgap for Longhorn |
| kube-prometheus-stack | `platform/prometheus.yaml` | Prometheus + Grafana + node-exporter + kube-state-metrics; Alertmanager off |
| 1Password Connect | `platform/onepassword-connect.yaml` | reads the 1Password vault `K8S`; its own credential is a hand-made Secret |
| External Secrets Operator | `platform/external-secrets-operator.yaml` + `platform/external-secrets/` | turns `ExternalSecret`s into Secrets via the `onepassword` ClusterSecretStore |
| cert-manager | `platform/cert-manager.yaml` + `platform/cert-manager/` | Let's Encrypt via Cloudflare DNS-01 for `*.home.juangar.com` |
| cloudflared | `platform/cloudflared.yaml` → `platform/cloudflared/` | Cloudflare Tunnel connector publishing `juangar.com`; 2 replicas |
| resume site | `apps/resume.yaml` → `apps/resume/` | image built from `site/`; 2 replicas; queries Prometheus through a same-origin proxy |

### Envoy Gateway

Replaced Traefik when the cluster moved from microk8s to kubeadm. Chosen over
Cilium's own Gateway API implementation because that requires
`kubeProxyReplacement` enabled, and this cluster deliberately keeps kube-proxy
for now (see `cilium-values.yaml`).

One `Gateway` (`platform/envoy-gateway/gateway.yaml`) serves every hostname,
unlike Traefik's old per-node `hostPort` DaemonSet where any Pi's IP worked.
The Gateway's auto-created Service is `type: LoadBalancer` and draws its
single shared IP from the MetalLB pool (`platform/metallb/ipaddresspool.yaml`) - check
`kubectl get svc -n envoy-gateway-system` for the actual address; nothing
pins it to a specific one in this pass. Point DNS/hosts at that IP, not at a
node.

Envoy runs **two replicas on different nodes**
(`platform/envoy-gateway/envoyproxy.yaml`, attached through the Gateway's
`spec.infrastructure.parametersRef`). The Service uses
`externalTrafficPolicy: Local`, so MetalLB only announces the IP from a node
with a ready Envoy pod; with one replica, losing that node took the entry
point down for minutes. Measured failover behaviour is in
[`networking-explained.md`](networking-explained.md#what-happens-when-a-pi-dies-measured).

Listeners: `http` (port 80, any hostname) plus one HTTPS listener per
LAN hostname (`https-resume`, `https-grafana`, port 443). Two rules keep
them working:

- **One certificate per listener.** Gateway API only guarantees a single
  `certificateRefs` entry per listener; more is implementation-specific.
  Don't merge them into one multi-certificate listener.
- **Certificates live next to the Gateway.** A listener may only reference
  Secrets in the Gateway's namespace (otherwise `ResolvedRefs=False`,
  `RefNotPermitted`, unless a ReferenceGrant allows it). cert-manager writes
  the Secret into the Certificate's namespace, so the Certificates are in
  `envoy-gateway-system`, not in the apps' namespaces.

`HTTPRoute` resources attach via `parentRefs` (`apps/resume/values.yaml`'s
`route` block, `grafana.route.main` in `prometheus-values.yaml`). Both pin
`sectionName`, so a route needs **one parentRef per listener** it should
serve — a hostname with a valid certificate but no parentRef for its HTTPS
listener gets a 404. `juangar.com` needs no HTTPS listener: Cloudflare
terminates its TLS, and cloudflared delivers it to the `http` listener.

Both the Gateway API CRDs and Envoy Gateway's own CRDs ship bundled in the
`gateway-helm` chart's `crds` subchart (`crds.enabled: true` by default) - do
not add a separate Gateway API CRDs Application; two Applications owning the
same CRDs would fight over them.

**Hooks.** The chart's `certgen` Job and its RBAC are Helm
`pre-install`/`pre-upgrade` hooks. ArgoCD runs those as PreSync hooks on
every full sync (not on selective syncs); with no delete policy it assumes
`BeforeHookCreation`, deleting the previous Job before creating the next, so
chart bumps don't hit immutable-field errors. What ArgoCD never does is prune
a hook object the chart has stopped rendering — those need deleting by hand.
The chart's topology injector (a mutating webhook, also shipped as a hook) is
disabled in `envoy-gateway-values.yaml`: these Pis have no zone labels for it
to add, and as a hook it was deleted after every sync anyway.

### Adopting an already-running release (Cilium)

Cilium was installed by hand during the kubeadm cluster bootstrap, before
ArgoCD existed. Bringing an existing release under GitOps management (rather
than a fresh install) has one real risk: **values drift**, not resource
identity. If the values committed to git don't exactly match what's already
live, syncing changes the `cilium-config` ConfigMap, which restarts every
agent DaemonSet pod on all three nodes at once - a cluster-wide networking
blip, not a "just re-sync it" situation.

The runbook `platform/cilium.yaml` follows:

1. `helm get values cilium -n kube-system` to get the exact user-supplied
   overrides (not `-a`, which dumps the full computed defaults too) - seed
   `cilium-values.yaml` with exactly that.
2. Commit with `platform/cilium.yaml`'s `syncPolicy` left **manual** (no
   `automated` block) - deliberately, so the first sync doesn't happen
   without a look.
3. Once ArgoCD detects the Application, run `argocd app diff cilium`.
4. Only once that diff is empty (or only adds ArgoCD's own tracking label),
   sync once manually.
5. Then, and only then, add the standard
   `syncPolicy.automated: {prune: true, selfHeal: true}` block used by every
   other platform Application here.

This same pattern applies to adopting anything else already running unmanaged
on the cluster.

### LoadBalancer IPs: MetalLB (L2 mode)

MetalLB hands out LoadBalancer IPs from `192.168.0.210`–`192.168.0.230`
(`platform/metallb/ipaddresspool.yaml`) and answers ARP for them from one
node at a time (`platform/metallb/l2advertisement.yaml`, pinned to `eth0`).
Chosen over Cilium's built-in equivalent because it doesn't depend on the
CNI, so the same setup carries to any bare-metal cluster. Cilium's own
LB-IPAM is switched off (`defaultLBServiceIPAM: none` in
`cilium-values.yaml`) so the two can never claim the same address.

**`speaker.ignoreExcludeLB: true` is required here.** kubeadm labels every
control-plane node `node.kubernetes.io/exclude-from-external-load-balancers`,
and MetalLB's speaker won't announce from a labelled node. All three nodes
here are control-plane, so without the flag a Service gets its
`EXTERNAL-IP` and nothing on the LAN can reach it: no node answers ARP. In
L2 mode that skip is logged only at debug level, so from the outside it
looks like a speaker bug.

That is exactly how it was misread the first time. A `tcpdump` on `eth0`
showed client ARP requests arriving and no reply, and a manual
`ip addr add <ip>/32 dev eth0` made the IP reachable instantly — which
proved the network path fine but was wrongly taken as proof of a MetalLB
defect. The cluster spent a day on Cilium's L2 announcer (commit `1141a89`,
whose message repeats the wrong diagnosis) before the label was found. It's
in MetalLB's troubleshooting docs under "MetalLB is not advertising my
service from my control-plane nodes". If a node is ever added as a pure
worker, it will not carry the label and needs nothing special.

### Storage: local-path-provisioner, not Longhorn (yet)

The kubeadm rebuild left the cluster with no StorageClass at all - not
"the old one doesn't work," genuinely none - which the Prometheus Operator
treats as fatal rather than leaving the pod `Pending`:
`sync "monitoring/prometheus-kube-prometheus-prometheus" failed: storage
class "microk8s-hostpath" does not exist`. No Prometheus server ran at all
until this was fixed.

Longhorn is the architecturally "correct" fix - real replicated storage
across all 3 nodes, already anticipated by the kubeadm guide's OS-prep step
(`open-iscsi`/`nfs-common` are already installed for it) - but it's a bigger
lift than "get something working now" called for. `local-path-provisioner`
is a single small pod that creates the `local-path` StorageClass immediately,
sourced directly from its chart in the upstream git repo (no published Helm
repo exists for it, but ArgoCD supports a chart path in any git repo the same
as a packaged one).

The trade-off is real, not swept under the rug: a PVC's data lives on
whichever one node it happened to land on (`volumeBindingMode:
WaitForFirstConsumer`), with zero replication. If that node goes down, that
PVC's data is unavailable until it's back. Acceptable for Prometheus/Grafana
- metrics history and dashboards aren't irreplaceable - not something to
build anything requiring real HA storage on top of. Swapping to Longhorn
later is a one-line change per consumer (`storageClassName: local-path` →
whatever Longhorn's class is named), nothing else here changes.

### Prometheus

kube-prometheus-stack rather than the bare prometheus chart, because the
bundle also brings node-exporter (node CPU/memory series) and
kube-state-metrics (`kube_*` series) — the latter being what the resume site's
pod count, deployments table and node roles depend on.

Grafana is enabled and is the only Grafana in the cluster. The chart
provisions the standard Kubernetes dashboards automatically; add custom ones
under `grafana.dashboards` in `prometheus-values.yaml` so they are
version-controlled rather than living only in the pod.

Alertmanager stays disabled (no paging setup on a homelab). The control-plane
ServiceMonitors (scheduler, controller-manager, proxy, etcd) stay off too -
they were disabled because the old microk8s cluster bound those components to
127.0.0.1, making them unreachable. kubeadm's defaults may well expose the
scheduler and controller-manager on `0.0.0.0` now, which would make
re-enabling them a real near-term improvement, but that's deferred to a later
pass, not done here.

One relabeling worth knowing about: the node-exporter ServiceMonitor rewrites
the `instance` label to the node name. Without it, anything querying these
series sees pod IPs instead of `node01`.

**Grafana's memory limit is 512Mi, and must not go back to 256Mi.** At 256Mi
Grafana sat at its limit, and instead of being OOM-killed it *thrashed*: the
kernel kept evicting its page cache and it re-read its files from node03's
microSD card nonstop. That saturated the card that etcd, the API server and
the kubelet share, took node03 `NotReady` repeatedly, and pushed its pods onto
node01 until node01 had to be power-cycled. Per-container pressure
(`memory.pressure`/`io.pressure` in the pod's cgroup under
`/sys/fs/cgroup/kubepods.slice/`) is what found it — node-level numbers only
showed "node03 is slow". Grafana stays on node03 regardless: its
`local-path` volume is there.

## Secrets: External Secrets Operator + 1Password Connect

Every secret the cluster uses comes from the 1Password vault `K8S`, except
two that can't: Connect's own `1password-credentials.json` (Secret
`op-credentials` in `onepassword-connect`) and the token ESO uses to talk to
Connect (Secret `onepassword-connect-token` in `external-secrets`). They're
what unlock 1Password, so they're created by hand on each cluster build and
never go in git — see
[`cloudflare-1password-setup.md`](cloudflare-1password-setup.md), step 7, and
the "before you wipe" list in the install guide.

- The `onepassword` ClusterSecretStore (`platform/external-secrets/`) points
  ESO at Connect's in-cluster Service.
- Each `ExternalSecret` lives with the component that **consumes** it
  (`platform/cloudflared/`, `platform/cert-manager/`), not with ESO, so the
  consumer's Application owns the Secret and pruning ESO can't delete a
  Secret out from under a running workload.
- Items must be 1Password **Password** items (the only type besides Document
  that the Connect provider reads). `remoteRef.key` is the item title,
  `remoteRef.property` the field label — both items here use a field
  labelled `token`.
- To check a secret without revealing it, compare its length and first
  characters — that's how the tunnel ID stored in place of the tunnel token
  was caught.

## Certificates: cert-manager with Cloudflare DNS-01

`.lan` can never get a browser-trusted certificate — public authorities only
issue for registered domains — so LAN services also answer on
`*.home.juangar.com`. Those names have no public DNS records; cert-manager
proves ownership with **DNS-01**, writing a `_acme-challenge` TXT record
through Cloudflare's API, so the Pis never need to be reachable from the
internet. The API token is scoped to DNS edits on `juangar.com` only.

Two ClusterIssuers: `letsencrypt-staging` (untrusted, generous limits) and
`letsencrypt-prod` (strict: 5 duplicate certificates per week). Prove any
issuance change against staging first. The token's Secret is in the
`cert-manager` namespace because a ClusterIssuer looks up referenced Secrets
in cert-manager's own namespace. Beginner-level walkthrough:
[`public-access-explained.md`](public-access-explained.md), Part 6.

## Public exposure: Cloudflare Tunnel

`juangar.com` reaches the cluster through a Cloudflare Tunnel: two
cloudflared pods dial out to Cloudflare and keep connections open; no router
port is opened and the home IP is never published. Full explanation, and the
DNS trap that delayed launch, in
[`public-access-explained.md`](public-access-explained.md).

Three things live **outside this repo**, in Cloudflare's dashboard, and can
break the public site with no diff here:

- The zone's DNS records — `juangar.com` must be a proxied CNAME to
  `<tunnel-ID>.cfargotunnel.com`.
- The tunnel's route: `juangar.com` →
  `http://envoy-envoy-gateway-system-eg-5391c79d.envoy-gateway-system.svc.cluster.local:80`,
  Host header `juangar.com`. That Service name is **generated** by Envoy
  Gateway from the Gateway's namespace, name and a hash; recreate the Gateway
  under another name and the route silently points at nothing.
- The tunnel token (in 1Password, fetched by ESO).

**Deliberate decision:** publishing the site also publishes its live cluster
metrics (node CPU/memory, pod and deployment counts) through the Prometheus
proxy. That's intended for a portfolio piece. The abuse control is nginx's
per-client rate limit, which only works because `nginx.realIp` makes nginx
see the real visitor address instead of Envoy's (details in
`apps/resume/values.yaml`).

## ArgoCD: server-side diff

`controller.diff.server.side: "true"` (`argocd-values.yaml`) makes ArgoCD ask
the API server what applying git's version would produce and compare that
with live, instead of comparing raw git YAML. Without it, fields the API
server fills in with defaults — Gateway API objects have many — read as
drift, and `envoy-gateway` and `prometheus` sat permanently `OutOfSync` with
nothing actually different.

## How the resume site gets its cluster data

```
LAN:     browser ─────────────────────────────┐
public:  browser ──> Cloudflare ──> cloudflared ┴──> Envoy ──> resume pod (nginx)
                                                                 │  location = /api/v1/query
                                                                 └──> prometheus-kube-prometheus-prometheus.monitoring:9090
```

The page's JavaScript calls `/api/v1/query` on its own origin; nginx proxies
that single endpoint to Prometheus inside the cluster. Prometheus is never
exposed through an Ingress, and there is no CORS to configure.

Two coupling points to remember, because nothing enforces them:

1. `prometheus.proxy.url` in `apps/resume/values.yaml` must match the Service
   name produced by `releaseName:` in `platform/prometheus.yaml`.
2. The node-exporter `instance` relabeling in `platform/prometheus-values.yaml`
   is what makes the site show node names instead of pod IPs.

## Adding a new app

1. Copy `apps/resume/` to `apps/<name>/`, edit the chart. Rename the
   `resume.*` named templates in `_helpers.tpl` to match - template names are
   global across a chart and its subcharts, so leaving them collides.
2. Copy `clusters/rpi-cluster/apps/resume.yaml` to
   `clusters/rpi-cluster/apps/<name>.yaml`, update `metadata.name`,
   `spec.source.path`, and `spec.destination.namespace`.
3. Commit and push. ArgoCD picks it up on its next reconcile (default: 3m,
   or immediately if `argocd app sync root` is run).

`apps/resume` is written as the reference chart for this repo - heavily
commented, and exercising the Helm features you'd reach for in a real chart.
See [`helm-workflow.md`](helm-workflow.md) for the local edit/verify loop.

## Adding a platform component

Add a new `Application` under `clusters/rpi-cluster/platform/`. For
third-party components prefer an Application sourced directly from the
upstream Helm chart repo, like `envoy-gateway.yaml` does, over vendoring the
chart into this repo.

If the component also needs plain CR manifests alongside its chart (an
`IPAddressPool`, a `Gateway`, anything that isn't itself a Helm release), add
a third source to the same Application pointing at
`platform/<component>/` at the **top level of the repo** - see
`envoy-gateway.yaml`, `metallb.yaml` or `cert-manager.yaml`. That path must NOT be under
`clusters/rpi-cluster/`: the root Application's `directory.recurse: true`
already watches that whole subtree, so a plain manifest placed there gets
applied twice - once by `root`, once by the component's own Application - a
real shared-resource conflict, not a hypothetical one.

Two options that matter for real charts, both used by `prometheus.yaml`:

- `ServerSideApply=true` — required for any chart with large CRDs. Client-side
  apply writes the whole manifest into an annotation, and the Prometheus
  Operator CRDs blow past the 262kB limit, failing with
  "metadata.annotations: Too long".
- `SkipDryRunOnMissingResource=true` — lets the first sync proceed when a
  resource's CRD is installed by that same chart.

If the component needs a secret, add an `ExternalSecret` in its own
`platform/<component>/` folder (see "Secrets" above) rather than a Secret. If
its chart uses Helm hooks, read the Envoy Gateway "Hooks" note: ArgoCD runs
them, but never prunes one the chart stops rendering.

## Before deleting anything in the cluster

Deleting and letting ArgoCD reinstall is not symmetric: the delete needs a
healthy control plane, the reinstall needs a healthy control plane *and* a
working ArgoCD. `kubectl delete namespace` in particular is finalised by the
namespace controller inside kube-controller-manager — if that controller is not
reconciling, the namespace sticks in `Terminating` forever and clearing it
means editing finalizers by hand.

One command tells you whether the control plane is actually working. A healthy
controller-manager creates the ReplicaSet within a second or two:

```sh
kubectl create deployment ctrltest --image=busybox:1.36 -- sleep 60
kubectl get rs -l app=ctrltest        # non-empty immediately = safe to proceed
kubectl delete deployment ctrltest
```

Leases are not a health check. Both the scheduler and controller-manager can
keep renewing their leader lease while doing no work at all, which means
leadership never fails over and `kubectl get lease` looks fine while nothing
reconciles. Test behaviour, not liveness.
