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
.github/workflows/               image build + digest write-back
docs/rebuild.md                  rebuilding the cluster from scratch
```

`site/` is the odd one out: it holds the HTML/CSS and Dockerfile that become
the container image, not anything applied to the cluster. ArgoCD's root
Application only watches `clusters/rpi-cluster`, so nothing under `site/` is
ever synced — including the legacy `site/k8s.yaml`, which is superseded by
`apps/resume` and kept only as a plain-manifest reference.

`platform/<component>/` is the newer sibling to `apps/<name>/`: a place for
plain Kubernetes manifests (not a Helm chart) that belong to a platform
Application - CRs like Cilium's `CiliumLoadBalancerIPPool` or Envoy
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
| Cilium | `platform/cilium.yaml` + `platform/cilium/` | CNI, LoadBalancer IPAM and L2 announcer; adopted from the kubeadm bootstrap install, manual sync until diff is confirmed empty |
| Envoy Gateway | `platform/envoy-gateway.yaml` + `platform/envoy-gateway/` | Gateway API implementation; replaced Traefik |
| local-path-provisioner | `platform/local-path-provisioner.yaml` | dynamic, non-replicated `local-path` StorageClass; stopgap for Longhorn |
| kube-prometheus-stack | `platform/prometheus.yaml` | Prometheus + Grafana + node-exporter + kube-state-metrics; Alertmanager off |
| resume site | `apps/resume.yaml` → `apps/resume/` | image built from `site/`; queries Prometheus through a same-origin proxy |

### Envoy Gateway

Replaced Traefik when the cluster moved from microk8s to kubeadm. Chosen over
Cilium's own Gateway API implementation because that requires
`kubeProxyReplacement` enabled, and this cluster deliberately keeps kube-proxy
for now (see `cilium-values.yaml`).

One `Gateway` (`platform/envoy-gateway/gateway.yaml`) serves every hostname,
unlike Traefik's old per-node `hostPort` DaemonSet where any Pi's IP worked.
The Gateway's auto-created Service is `type: LoadBalancer` and draws its
single shared IP from Cilium's `CiliumLoadBalancerIPPool` (`platform/cilium/loadbalancer-ip-pool.yaml`) - check
`kubectl get svc -n envoy-gateway-system` for the actual address; nothing
pins it to a specific one in this pass. Point DNS/hosts at that IP, not at a
node.

`HTTPRoute` resources attach to the Gateway via `parentRefs` (see
`apps/resume/values.yaml`'s `route` block, or `grafana.route.main` in
`prometheus-values.yaml`). There is no HTTPS listener yet - TLS needs
cert-manager, which is deferred, so `resume.lan`/`grafana.lan` lose HTTPS
until then.

Both the Gateway API CRDs and Envoy Gateway's own CRDs ship bundled in the
`gateway-helm` chart's `crds` subchart (`crds.enabled: true` by default) - do
not add a separate Gateway API CRDs Application; two Applications owning the
same CRDs would fight over them.

**Known follow-up:** the chart's `certgen` Job is a Helm
`pre-install`/`pre-upgrade` hook, which ArgoCD ignores by this repo's
convention. A future `targetRevision` bump will fail on an immutable-field
error because the old Job blocks recreation - delete it manually
(`kubectl delete job -n envoy-gateway-system <name>`) as part of that sync,
or add `Replace=true` for that one sync.

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

### LoadBalancer IPAM and L2 announcement (Cilium, not MetalLB)

MetalLB was tried first (the standard bare-metal choice), but its L2 speaker
had a confirmed bug: it correctly ran duplicate-address detection for a new
LoadBalancer IP (visible in its logs as an ARP *request*, sourced from the
node's own IP, asking who currently holds the address) but then never sent
the actual ARP *reply* to a real client's query - proven with a `tcpdump` on
the node's `eth0` showing the client's request arriving and nothing ever
answering it. This was isolated from a Cilium or network problem by manually
running `ip addr add <ip>/32 dev eth0` on the node and confirming the same
IP became reachable instantly - so the network path, Cilium's eBPF datapath,
and XDP were all fine; the defect was specifically in MetalLB's speaker.

Cilium 1.20 has the same two features (`enableLBIPAM` - LoadBalancer IP
allocation, chart default `true`; `l2announcements` - the ARP/NDP responder)
built into the agent already running on every node, so there's no separate
raw-socket process to have this class of bug. `platform/cilium/` holds the
`CiliumLoadBalancerIPPool` (replaces MetalLB's `IPAddressPool`) and
`CiliumL2AnnouncementPolicy` (replaces `L2Advertisement`), both restricted to
`eth0` explicitly - MetalLB had created ARP responders on both `eth0` and
Cilium's own `cilium_vxlan` interface, which was one candidate explanation
for the bug, so this stays unambiguous even though Cilium's own L2 announcer
is different code.

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
series sees pod IPs instead of `pi-01`.

## How the resume site gets its cluster data

```
browser ──> Envoy Gateway ──> resume pod (nginx)
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
`cilium.yaml` or `envoy-gateway.yaml`. That path must NOT be under
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
