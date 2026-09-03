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
| resume site | `apps/resume.yaml` → `apps/resume/` | image built from `site/`; queries Prometheus through a same-origin proxy |

## What this repo deliberately does NOT manage

The cluster predates this repo and already runs several things. This repo
consumes them rather than duplicating them:

| Already in the cluster | Namespace | Why we don't manage it |
| --- | --- | --- |
| Prometheus + Grafana + node-exporter | `monitoring` | hand-rolled Deployment driven by the `prometheus-config` ConfigMap; adopting it into GitOps would be a separate, deliberate migration |
| ingress-nginx (classes `public`, `nginx`) | microk8s addon | the `ingress` addon already owns :80/:443 |
| MetalLB | `metallb-system` | LoadBalancer Services already work |
| in-cluster registry | `container-registry` | we push to ghcr.io instead, so images survive a cluster rebuild |

Adding a second ingress controller or a second Prometheus was tried and
reverted — see the "two default IngressClasses" trap below.

### If you add an ingress controller later

Only one IngressClass may carry
`ingressclass.kubernetes.io/is-default-class: "true"`. Installing a second
controller that also marks itself default leaves two defaults, and any
Ingress without an explicit `spec.ingressClassName` becomes ambiguous. Always
set the class explicitly, as `apps/resume/values.yaml` does.

## How the resume site gets its cluster data

```
browser ──> ingress-nginx ──> resume pod (nginx)
                                │  location = /api/v1/query
                                └──> prometheus.monitoring:9090   (pre-existing)
```

The page's JavaScript calls `/api/v1/query` on its own origin; nginx proxies
that single endpoint to Prometheus inside the cluster. Prometheus is never
exposed through an Ingress, and there is no CORS to configure.

`prometheus.proxy.url` in `apps/resume/values.yaml` must match that Service.
Nothing enforces the link — if the monitoring stack is ever renamed or
migrated, the panels silently fall back to cached values.

### What the panels can and cannot show today

The existing Prometheus scrapes node-exporter, the kubelet/cAdvisor and the
API server, but **not kube-state-metrics — which is not deployed anywhere in
the cluster**. So:

| Panel | Query | Works today? |
| --- | --- | --- |
| CPU / memory per node | `node_*` | yes |
| Pod count | `kube_pod_info` | no — no KSM |
| Deployments table | `kube_deployment_*` | no — no KSM |
| Node roles | `kube_node_role` | no — no KSM |

The site degrades to its hardcoded fallback for anything missing, so nothing
breaks; those panels just show cached values.

Node names also read as IPs (`192.168.0.42`) rather than `master`/`worker1`,
because the existing `node-exporter` scrape job does not relabel `instance` to
the node name.

Making all of that live needs two changes to the **existing, unmanaged**
monitoring stack: deploy kube-state-metrics, and add a scrape job plus an
`instance` relabeling to the `prometheus-config` ConfigMap. Both are out of
scope here precisely because that stack is not managed by this repo.

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
upstream Helm chart repo, like `argocd.yaml` does, over vendoring the chart
into this repo.

Two sync options worth knowing when you add a chart that ships CRDs:

- `ServerSideApply=true` — required for any chart with large CRDs. Client-side
  apply writes the whole manifest into an annotation, and the Prometheus
  Operator CRDs blow past the 262kB limit, failing with
  "metadata.annotations: Too long".
- `SkipDryRunOnMissingResource=true` — lets the first sync proceed when a
  resource's CRD is installed by that same chart.
