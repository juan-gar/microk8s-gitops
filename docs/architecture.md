# Architecture

## Layout

```
bootstrap/                       one-time, manually-applied Application (the "root")
clusters/rpi-cluster/
  platform/                      cluster-wide infrastructure Applications
  apps/                          workload Applications, one file per app
apps/<name>/                     the actual Helm chart for each workload (Chart.yaml, values.yaml, templates/)
```

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
| kube-prometheus-stack | `platform/prometheus.yaml` | Prometheus + node-exporter + kube-state-metrics; Grafana and Alertmanager off |

### Traefik

Runs as a DaemonSet with `hostPort` 80/443 rather than a LoadBalancer Service,
because there is no LoadBalancer implementation on bare metal until MetalLB is
scaffolded. One Traefik per node means any Pi's IP serves the cluster's
Ingresses, so DNS can point at any of them.

microk8s also ships an nginx-based `ingress` addon. Running both is a
conflict: two controllers claiming the same Ingress objects and both wanting
:80/:443 on the host. This repo standardises on Traefik.

### Prometheus

kube-prometheus-stack rather than the bare prometheus chart, because the
bundle also brings node-exporter (node CPU/memory series) and
kube-state-metrics (`kube_*` series). Grafana and Alertmanager are disabled to
save memory, and the control-plane scrape targets microk8s does not expose
(scheduler, controller-manager, proxy, etcd) are turned off so the targets
page stays honest.

One relabeling worth knowing about: the node-exporter ServiceMonitor rewrites
the `instance` label to the node name. Without it, anything querying these
series sees pod IPs instead of `pi-01`.

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
