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
clusters/rpi-cluster/platform/   cluster infrastructure (ArgoCD itself, and later ingress/monitoring)
clusters/rpi-cluster/apps/       workload Applications
apps/                            the Helm chart backing each workload
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

4. Confirm all four Applications show up and sync — `argocd`, `traefik`,
   `prometheus`, `resume`:

   ```sh
   microk8s kubectl get applications -n argocd
   ```

   `prometheus` is the slow one: it installs the Prometheus Operator CRDs
   first, and on Pi hardware the whole stack can take several minutes to go
   Healthy. `Progressing` is expected for a while.

   Do **not** also run `microk8s enable ingress` — that installs a second
   ingress controller which will fight Traefik for ports 80/443.

From here, all changes - including upgrading ArgoCD itself - go through
git: edit a manifest, commit, push, let ArgoCD sync.

## What's scaffolded so far

- **ArgoCD**, self-managed via the app-of-apps pattern.
- **Traefik**, a DaemonSet binding hostPort 80/443 on every Pi.
- **kube-prometheus-stack** — Prometheus, node-exporter and kube-state-metrics,
  tuned down for Pi hardware (Grafana and Alertmanager off).
- **`apps/resume`** — the resume site chart, and the reference chart for this
  repo. Heavily commented as a Helm tutorial; copy it for new apps.

The site reads live cluster state from Prometheus through a same-origin nginx
proxy — see [`docs/architecture.md`](docs/architecture.md) for the request
path.

### Before the resume app will serve

The chart points at `ghcr.io/juan-gar/resume-web`, which does not exist yet —
the site source and its image build are not in the repo at this point. Until
then the Application will sync but the pod cannot pull.

`ingress.hosts[0].host` is `resume.lan`. Traefik runs on every node with
hostPort 80, so any node's IP works; an `/etc/hosts` entry is enough to test.

Check the proxy target matches your cluster:

```sh
microk8s kubectl get svc -n monitoring            # prometheus.proxy.url
microk8s kubectl get svc -n kube-system kube-dns  # prometheus.proxy.resolver
```

Not yet scaffolded: persistent storage beyond Prometheus's hostpath PVC,
cert-manager/TLS, MetalLB, and secrets management (SOPS/sealed-secrets). Add
each as a new file under `clusters/rpi-cluster/platform/` following the
pattern in `traefik.yaml`.
