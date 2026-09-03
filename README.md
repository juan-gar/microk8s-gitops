# microk8s-gitops

GitOps source of truth for ArgoCD running on a 3-node Raspberry Pi microk8s
cluster.

See [`docs/architecture.md`](docs/architecture.md) for how the repo is laid out
and how to add apps and platform components.

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

4. Confirm the `argocd` Application shows up and syncs:

   ```sh
   microk8s kubectl get applications -n argocd
   ```

From here, all changes - including upgrading ArgoCD itself - go through
git: edit a manifest, commit, push, let ArgoCD sync.

## What's scaffolded so far

- **ArgoCD**, self-managed via the app-of-apps pattern.

Not yet scaffolded: an ingress controller, monitoring, workloads, persistent
storage, cert-manager/TLS, and secrets management (SOPS/sealed-secrets). Add
each as a new file under `clusters/rpi-cluster/platform/` following the
pattern in `argocd.yaml`.
