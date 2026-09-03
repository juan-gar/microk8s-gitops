# Architecture

## Layout

```
bootstrap/                       one-time, manually-applied Application (the "root")
clusters/rpi-cluster/
  platform/                      cluster-wide infrastructure Applications
  apps/                          workload Applications, one file per app
apps/<name>/                     the actual Helm chart for each workload (Chart.yaml, values.yaml, templates/)
site/                            source for the resume site image (built by CI, not synced by ArgoCD)
.github/workflows/               image build + digest write-back
docs/rebuild.md                  rebuilding the cluster from scratch
```

`site/` is the odd one out: it holds the HTML/CSS and Dockerfile that become
the container image, not anything applied to the cluster. ArgoCD's root
Application only watches `clusters/rpi-cluster`, so nothing under `site/` is
ever synced — including the legacy `site/k8s.yaml`, which is superseded by
`apps/resume` and kept only as a plain-manifest reference.

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
| Traefik | `platform/traefik.yaml` | DaemonSet, hostPort 80/443 |
| kube-prometheus-stack | `platform/prometheus.yaml` | Prometheus + Grafana + node-exporter + kube-state-metrics; Alertmanager off |
| resume site | `apps/resume.yaml` → `apps/resume/` | image built from `site/`; queries Prometheus through a same-origin proxy |

### Traefik

Runs as a DaemonSet with `hostPort` 80/443 rather than a LoadBalancer Service,
because there is no LoadBalancer implementation on bare metal until MetalLB is
scaffolded. One Traefik per node means any Pi's IP serves the cluster's
Ingresses, so DNS can point at any of them.

microk8s also ships an nginx-based `ingress` addon. Leave it disabled: two
controllers claiming the same Ingress objects and both wanting :80/:443 is a
conflict, and both mark their IngressClass as default — leaving two defaults,
at which point any Ingress without an explicit `className` is ambiguous.

Always set `spec.ingressClassName` explicitly anyway, as `apps/resume` and the
Grafana values do. It costs nothing and survives this kind of mistake.

### The Service type trap

The chart's Service type lives at **`service.spec.type`**, not `service.type`.
A top-level `service.type` is silently ignored — the values schema accepts the
stray key and the default (`LoadBalancer`) applies anyway. That is how an
earlier version of this file ended up putting Traefik on a MetalLB address
another gateway already held, with overlapping :80/:443.

Since Traefik here is a DaemonSet with `hostPort`, it wants `ClusterIP` and no
LoadBalancer address at all. Verify after any change to this file:

```sh
helm template traefik traefik/traefik --version 41.4.0 \
  -f clusters/rpi-cluster/platform/traefik-values.yaml \
  | grep -A2 'kind: Service'
```

The general lesson: a values key that does nothing produces no error anywhere.
Check the rendered output, not the values file.

### Prometheus

kube-prometheus-stack rather than the bare prometheus chart, because the
bundle also brings node-exporter (node CPU/memory series) and
kube-state-metrics (`kube_*` series) — the latter being what the resume site's
pod count, deployments table and node roles depend on.

Grafana is enabled and is the only Grafana in the cluster. The chart
provisions the standard Kubernetes dashboards automatically; add custom ones
under `grafana.dashboards` in `prometheus-values.yaml` so they are
version-controlled rather than living only in the pod.

Do **not** also enable the microk8s `prometheus` addon — it installs a second,
unmanaged operator.

Alertmanager stays disabled (no paging setup on a homelab), and the
control-plane scrape targets microk8s does not expose (scheduler,
controller-manager, proxy, etcd) are turned off so the targets page stays
honest.

One relabeling worth knowing about: the node-exporter ServiceMonitor rewrites
the `instance` label to the node name. Without it, anything querying these
series sees pod IPs instead of `pi-01`.

## How the resume site gets its cluster data

```
browser ──> Traefik ──> resume pod (nginx)
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
upstream Helm chart repo, like `traefik.yaml` does, over vendoring the chart
into this repo.

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
