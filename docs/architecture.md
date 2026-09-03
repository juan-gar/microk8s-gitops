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

## Adding a platform component

Add a new `Application` under `clusters/rpi-cluster/platform/`. For
third-party components (ingress controllers, monitoring, cert-manager, ...)
prefer an Application sourced directly from the upstream Helm chart repo,
like `argocd.yaml` does, over vendoring the chart into this repo.
