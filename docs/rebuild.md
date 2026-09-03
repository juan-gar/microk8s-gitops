# Rebuilding the cluster from scratch

Written after the first cluster accumulated two years of undocumented state —
a hand-rolled Prometheus, IngressClasses with no controller behind them, addons
enabled and disabled inconsistently, and a service mesh nobody was using. The
point of a rebuild is that afterwards **everything running is in git**, and
this file exists so the next rebuild is a checklist rather than an
archaeological dig.

Work top to bottom. Steps 1–3 happen before you erase anything.

---

## 1. Back up what you cannot regenerate

Inventory the live cluster first — you cannot ask it anything once it's gone:

```sh
kubectl get pvc -A -o wide                       # what has persistent data
kubectl get svc -A --field-selector spec.type=LoadBalancer   # which LAN IPs are in use
kubectl get ingress -A                           # which hostnames are served
kubectl get ns -o name                           # what's actually deployed
```

Then copy the data off. hostpath volumes live on the node the PV is pinned to,
under `/var/snap/microk8s/common/default-storage/`:

```sh
kubectl get pv -o custom-columns=\
'PV:.metadata.name,CLAIM:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'

# then, on the node each PV is pinned to:
sudo tar czf ~/pv-<claim>.tgz -C /var/snap/microk8s/common/default-storage <dir>
```

### The one that will bite you

**Anything serving the house.** On the first cluster that was Pi-hole, holding
a MetalLB address and answering DNS on `:53` for the whole network. Wiping it
takes the network's DNS down with it, and you will be debugging the rebuild
without working name resolution.

Before you start: point the router at an upstream resolver (or a second
Pi-hole), confirm DNS still works from a laptop, *then* wipe. Back up its
config volume either way — the blocklists and local DNS records are tedious to
recreate.

### Things you do not need to back up

- Container images — they rebuild from `site/` via CI, or re-pull from ghcr.io.
- Anything ArgoCD manages from this repo. That's the whole point.
- Grafana dashboards you never exported. Accept the loss, and from now on put
  them in `prometheus-values.yaml` under `grafana.dashboards` so they're in git.

---

## 2. Decide the hardware layout

Two decisions that are painful to change later.

### Ethernet, not WiFi

The first cluster ran its control plane over `wlan0`. Every node was a dqlite
voter, so every write to the datastore needed quorum across WiFi. The result
was nodes flapping `NotReady`, `kine.sock` connection errors every ~30s, and
the scheduler and controller-manager wedging while still holding their leader
leases — so leadership never failed over and the cluster silently stopped
reconciling.

**Wire all three Pis.** If only some can be wired, the wired ones should be the
datastore voters.

### Storage

microk8s on an SD card works, but two years of container churn is a lot of
write amplification, and a failing card presents as random unexplained
misbehaviour rather than a clean error. A USB3 SSD for at least the node
holding persistent volumes is the single biggest reliability upgrade available.

While you're here, check the old cards before trusting them again:

```sh
sudo dmesg -T | grep -iE "mmc|i/o error|ext4.*error"
```

---

## 3. Decide what is NOT coming back

The old cluster ran istio, envoy-gateway, jaeger, loki, kiali and a Kubernetes
dashboard. A rebuild is the cheapest possible moment to drop what you aren't
using — each one is memory on a 4GB Pi and another thing that isn't in git.

Anything you *do* want back should come back as an Application under
`clusters/rpi-cluster/platform/`, not as a manual `helm install`. If it's worth
running, it's worth being in git; if it isn't worth the ten minutes to write
the Application, it probably isn't worth running.

---

## 4. Install

Ubuntu Server 24.04 LTS (arm64) on each Pi, then:

```sh
sudo snap install microk8s --classic
sudo usermod -aG microk8s "$USER" && newgrp microk8s
```

Form the cluster from the node you want as the primary:

```sh
microk8s add-node          # run once per node to join, following its instructions
microk8s status --wait-ready
```

Three nodes gives HA automatically (all three become datastore voters). That is
fine on Ethernet and was the problem on WiFi.

### Addons: enable only these

```sh
microk8s enable dns hostpath-storage helm3
```

**Do not enable** `ingress`, `prometheus`, `metrics-server`, `cert-manager` or
`observability`. Each duplicates something this repo manages, and the duplicate
is the copy that isn't in git — which is exactly the situation the rebuild is
meant to escape.

`metallb` is optional and only needed if something wants a real LAN IP
(Pi-hole's DNS did; Traefik here does not — it uses `hostPort`). If you enable
it, give it a range that does not overlap anything already on the LAN.

---

## 5. Bootstrap this repo

Follow [the README](../README.md#bootstrapping-a-fresh-cluster). In short:
install ArgoCD with the same chart version and values file this repo uses to
manage it, then apply `bootstrap/root-app.yaml` once. Everything else follows
from git.

---

## 6. Verify before declaring victory

```sh
# control plane actually reconciles (not just "lease is fresh")
kubectl create deployment ctrltest --image=busybox:1.36 -- sleep 60
kubectl get rs -l app=ctrltest && kubectl delete deployment ctrltest

# every Application healthy
kubectl get applications -n argocd

# exactly one default IngressClass
kubectl get ingressclass

# no LoadBalancer IP claimed twice
kubectl get svc -A --field-selector spec.type=LoadBalancer

# pods can reach the service network from every node
kubectl run nettest --image=busybox:1.36 --restart=Never -- \
  sh -c 'nc -z 10.152.183.1 443 && echo OK || echo FAIL'
kubectl logs nettest; kubectl delete pod nettest
```

Run the last one with the pod pinned to each node in turn
(`--overrides='{"spec":{"nodeName":"worker1"}}'`). On the first cluster,
service networking was broken on exactly one node while every configuration
file on it was byte-identical to a working node — a per-node check is the only
thing that catches that.

---

## Lessons the first cluster taught

- **A leader lease being renewed does not mean the component works.** Both the
  scheduler and controller-manager kept their leases while reconciling nothing.
  Test behaviour instead.
- **A values key that does nothing produces no error.** `service.type` instead
  of `service.spec.type` silently left Traefik as a LoadBalancer on an address
  another gateway already held. Check rendered output, not the values file.
- **An IngressClass with no controller is worse than a missing one.** It looks
  configured and serves nothing.
- **Compare against a working node before changing anything.** Several
  plausible theories here — a VPN route conflict, an iptables legacy/nft split,
  a reset sysctl — were each disproved in seconds by diffing a broken node
  against a healthy one. The diff is cheaper than the theory.
