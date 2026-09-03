# microk8s-gitops

GitOps source of truth for ArgoCD running on a 3-node Raspberry Pi microk8s
cluster.

- [`docs/architecture.md`](docs/architecture.md) — repo layout, how to add apps
  and platform components.
- [`docs/helm-workflow.md`](docs/helm-workflow.md) — the local Helm loop, and a
  map of which Helm concept is demonstrated in which file.

## Repo layout

```
bootstrap/                       one-time, manually-applied root Application
clusters/rpi-cluster/platform/   cluster infrastructure (ArgoCD)
clusters/rpi-cluster/apps/       workload Applications
apps/                            the Helm chart backing each workload
site/                            source for the resume site image (built by CI)
.github/workflows/               multi-arch image build + digest write-back
```

## Bootstrapping a fresh cluster

Assumes microk8s is installed and running on all three Pis, with a single
`kubectl`/`helm3` context pointed at the cluster.

1. Enable required microk8s addons:

   ```sh
   microk8s enable dns hostpath-storage helm3
   ```

2. Install ArgoCD via Helm, using the same chart version and values this
   repo uses to manage ArgoCD afterwards:

   ```sh
   microk8s helm3 repo add argo https://argoproj.github.io/argo-helm
   microk8s helm3 repo update

   microk8s helm3 install argocd argo/argo-cd \
     --version 10.6.4 \
     --namespace argocd --create-namespace \
     -f clusters/rpi-cluster/platform/argocd-values.yaml
   ```

3. Apply the root Application so ArgoCD starts managing everything in this
   repo, including its own installation:

   ```sh
   microk8s kubectl apply -f bootstrap/root-app.yaml
   ```

4. Confirm the `argocd` and `resume` Applications show up and sync:

   ```sh
   microk8s kubectl get applications -n argocd
   ```

From here, all changes - including upgrading ArgoCD itself - go through
git: edit a manifest, commit, push, let ArgoCD sync.

## What's scaffolded so far

- **ArgoCD**, self-managed via the app-of-apps pattern.
- **`apps/resume`** — the resume site chart, and the reference chart for this
  repo. Heavily commented as a Helm tutorial; copy it for new apps.

The cluster already provides ingress (ingress-nginx), monitoring (Prometheus +
Grafana + node-exporter in `monitoring`), MetalLB and a registry. This repo
**consumes** those rather than installing its own — see
[`docs/architecture.md`](docs/architecture.md) for what is deliberately not
managed here, and for the request path the site uses to reach Prometheus.

### Remaining steps before it serves

1. **Push the image once.** The chart points at `ghcr.io/juan-gar/resume-web`,
   built by `.github/workflows/build-site.yml`. It builds linux/arm64 (plus
   amd64) and writes the resulting digest back into `apps/resume/values.yaml`,
   which is what triggers the ArgoCD rollout.
   - Make the GHCR package public, or add a pull secret and set
     `imagePullSecrets` in values — GHCR packages default to private.
2. **Point DNS at the cluster.** `ingress.hosts[0].host` is `resume.lan`; an
   `/etc/hosts` entry pointing at a node IP is enough to test.
3. **Check the proxy target** matches your cluster:
   ```sh
   microk8s kubectl get svc -n monitoring            # prometheus.proxy.url
   microk8s kubectl get svc -n kube-system kube-dns  # prometheus.proxy.resolver
   microk8s kubectl get ingressclass                 # ingress.className
   ```

Some panels will show cached values until kube-state-metrics is deployed —
it isn't currently running in the cluster, so the `kube_*` series the pod
count, deployments table and node roles rely on don't exist. The CPU and
memory panels work. Details in [`docs/architecture.md`](docs/architecture.md).

Sync order mostly doesn't matter — the resume pod starts fine without
Prometheus and its panels fall back to cached values. The one failure mode that
*would* break it (nginx refusing to start when its proxy upstream doesn't
resolve) is deliberately avoided; see the comments in
`apps/resume/templates/configmap.yaml`.

Not managed here yet: cert-manager/TLS, secrets management
(SOPS/sealed-secrets), and adopting the existing monitoring stack into GitOps.
Add each as a new file under `clusters/rpi-cluster/platform/` following the
pattern in `argocd.yaml`.
