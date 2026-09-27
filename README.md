# pi-cluster-gitops

Everything for a 3-node Raspberry Pi Kubernetes cluster: how the cluster
itself is built (kubeadm, from bare Pis) and the GitOps source of truth
ArgoCD syncs onto it once it's up.

- [`docs/kubeadm-install-guide.md`](docs/kubeadm-install-guide.md) — building
  the cluster from bare Pis: kubeadm, stacked etcd, kube-vip, Cilium. Start
  here if there is no cluster yet; `scripts/` holds the per-node prep it uses.
- [`docs/networking-explained.md`](docs/networking-explained.md) — beginner's
  guide to how a request reaches an app: MetalLB, Envoy Gateway and Cilium,
  with analogies.
- [`docs/public-access-explained.md`](docs/public-access-explained.md) —
  beginner's guide to the planned public path: Namecheap, Cloudflare DNS, the
  tunnel and its route, and where secrets and certificates fit.
- [`docs/architecture.md`](docs/architecture.md) — repo layout, how to add apps
  and platform components.
- [`docs/helm-workflow.md`](docs/helm-workflow.md) — the local Helm loop, and a
  map of which Helm concept is demonstrated in which file.
- [`docs/rebuild.md`](docs/rebuild.md) — rebuilding the Pis from scratch: what
  to back up, hardware and HA decisions, and the verification checklist.
- [`docs/cloudflare-1password-setup.md`](docs/cloudflare-1password-setup.md) —
  the manual, outside-git steps in Cloudflare, Namecheap and 1Password that
  public exposure and cert-manager depend on.

## Repo layout

```
bootstrap/                       one-time, manually-applied root Application
clusters/rpi-cluster/platform/   cluster infrastructure Applications
clusters/rpi-cluster/apps/       workload Applications
apps/                            the Helm chart backing each workload
platform/<component>/            plain CR manifests belonging to a platform Application
scripts/                         per-node OS prep, run before kubeadm (see the install guide)
site/                            source for the resume site image (built by CI)
docs/                            install guide, architecture, external setup
.github/workflows/               multi-arch image build + digest write-back
```

Only `clusters/rpi-cluster` is watched by ArgoCD's root Application —
everything else here is either referenced explicitly by an Application
(`apps/`, `platform/`) or not deployed at all (`scripts/`, `docs/`, `site/`).

## Bootstrapping a fresh cluster

Assumes kubeadm is installed and running on all three Pis — see
[`docs/kubeadm-install-guide.md`](docs/kubeadm-install-guide.md) for that —
with `kubectl`/`helm` pointed at the cluster.

> Rebuilding existing Pis rather than starting fresh? Read
> [`docs/rebuild.md`](docs/rebuild.md) first for what to back up and the
> hardware decisions to make before wiping; OS and cluster formation then
> follow the install guide, not this file.

1. Install ArgoCD via Helm, using the same chart version and values this
   repo uses to manage ArgoCD afterwards:

   ```sh
   helm repo add argo https://argoproj.github.io/argo-helm
   helm repo update

   helm install argocd argo/argo-cd \
     --version 10.6.4 \
     --namespace argocd --create-namespace \
     -f clusters/rpi-cluster/platform/argocd-values.yaml
   ```

2. Apply the root Application so ArgoCD starts managing everything in this
   repo, including its own installation:

   ```sh
   kubectl apply -f bootstrap/root-app.yaml
   ```

3. Confirm the Applications show up and sync — `argocd`, `cilium`,
   `metallb`, `envoy-gateway`, `prometheus`, `resume`:

   ```sh
   kubectl get applications -n argocd
   ```

   `prometheus` is the slow one: it installs the Prometheus Operator CRDs
   first, and on Pi hardware the whole stack can take several minutes to go
   Healthy. `Progressing` is expected for a while.

   `cilium` syncs manually, not automatically — see
   [`docs/architecture.md`](docs/architecture.md#adopting-an-already-running-release-cilium)
   before touching it; it's adopting an already-running release, and an unintended
   values change restarts the CNI on every node at once.

From here, all changes - including upgrading ArgoCD itself - go through
git: edit a manifest, commit, push, let ArgoCD sync.

## What's scaffolded so far

- **ArgoCD**, self-managed via the app-of-apps pattern.
- **Cilium** — the cluster's CNI, adopted from the kubeadm bootstrap install.
- **MetalLB** — LoadBalancer IPs in L2 mode, pool
  `192.168.0.210`–`192.168.0.230`. Needs `ignoreExcludeLB: true` because
  every node is a kubeadm control-plane node — see `docs/architecture.md`.
- **Envoy Gateway** — Gateway API implementation fronting every hostname
  through one shared LoadBalancer IP (replaced Traefik's per-node hostPort
  model).
- **local-path-provisioner** — dynamic `local-path` StorageClass, not
  replicated (a PVC's data lives on whichever node it lands on). A stopgap
  for Longhorn — see `docs/architecture.md`.
- **kube-prometheus-stack** — Prometheus, Grafana, node-exporter and
  kube-state-metrics, tuned down for Pi hardware (Alertmanager off).
- **`apps/resume`** — the resume site chart, and the reference chart for this
  repo. Heavily commented as a Helm tutorial; copy it for new apps.

The site reads live cluster state from Prometheus through a same-origin nginx
proxy — see [`docs/architecture.md`](docs/architecture.md) for the request
path.

### Remaining steps before it serves

1. **Push the image once.** The chart points at `ghcr.io/juan-gar/resume-web`,
   which doesn't exist until `.github/workflows/build-site.yml` runs. Push a
   change under `site/`, or trigger the workflow manually. It builds
   linux/arm64 (plus amd64) and writes the resulting digest back into
   `apps/resume/values.yaml`, which is what triggers the ArgoCD rollout.
   - Make the GHCR package public, or add a pull secret and set
     `imagePullSecrets` in values — GHCR packages default to private.
2. **Point DNS at the Gateway.** `route.hostnames[0]` is `resume.lan`. Unlike
   Traefik's old hostPort DaemonSet, only ONE IP serves every hostname now —
   find it with `kubectl get svc -n envoy-gateway-system` (an address in
   `192.168.0.210`–`192.168.0.230`) and point an `/etc/hosts` entry or DNS
   record at that, not at a node.
3. **Check the two values that depend on cluster specifics.** Both defaults
   are usually right for this cluster, but nothing enforces them — a mismatch
   shows up as panels stuck on cached values, not an error:
   ```sh
   kubectl get svc -n monitoring            # prometheus.proxy.url
   kubectl get svc -n kube-system kube-dns  # prometheus.proxy.resolver (10.96.0.10 on this cluster)
   ```

Sync order mostly doesn't matter — the resume pod starts fine without
Prometheus and its panels fall back to cached values. The one failure mode that
*would* break it (nginx refusing to start when its proxy upstream doesn't
resolve) is deliberately avoided; see the comments in
`apps/resume/templates/configmap.yaml`.

Not yet scaffolded: cert-manager/TLS, replicated storage (Longhorn - see
`docs/architecture.md` for why `local-path-provisioner` is standing in for
it), and secrets management (External Secrets Operator + 1Password Connect).
Add each
as a new file under `clusters/rpi-cluster/platform/` following the pattern in
`envoy-gateway.yaml` (or `cilium.yaml` if it also needs plain CR manifests
alongside its chart — see `docs/architecture.md`).
