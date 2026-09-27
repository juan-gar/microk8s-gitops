# kubeadm Install Guide — 3-Node Pi Cluster

Sep 25, 2026 · @Juan

Rebuild the 3-node Raspberry Pi 4 cluster on kubeadm v1.35 with a highly available, stacked control plane on all three nodes, containerd 2.x, kube-vip for the API server VIP and Cilium as CNI. v1.35 is the version the CKA exam runs on today, and HA control planes are an explicit curriculum item.

## 1. Before you wipe

Everything in `control-plane` comes back on its own; these do not, because they live outside git.

- [ ] 1Password Connect bootstrap: `1password-credentials.json` and the Connect access token. External Secrets Operator can't fetch anything until these exist as Secrets again.
- [ ] Longhorn volume data you care about (Grafana state not in git, Ollama models if you don't want to re-pull, anything else stateful). Back up to the Synology NFS target or copy out with `kubectl cp`.
- [ ] Any other hand-applied Secret: `kubectl get secrets -A` and check which ones ESO didn't create.
- [ ] If Pi-hole runs on this cluster, move LAN DNS to the Synology or the router for the rebuild window, otherwise the nodes lose name resolution mid-install.
- [ ] Note the current LoadBalancer IP pool range (MetalLB's `IPAddressPool`, `192.168.0.210`–`.230`); the new API server VIP must sit outside it and outside the DHCP range.

## 2. Design decisions

| Choice | Pick | Why |
| --- | --- | --- |
| Kubernetes | v1.35.x | Matches the CKA exam environment. Upgrading to 1.36 later with `kubeadm upgrade` is itself exam practice. |
| Control plane | Stacked etcd on all 3 nodes, untainted | HA control plane is a CKA curriculum item; 3 members keep etcd quorum with one node down. |
| API endpoint | kube-vip VIP (ARP, static pod) | `controlPlaneEndpoint` can't be added after `kubeadm init`, so set it from day one. |
| Runtime | containerd 2.x | Kubernetes 1.35 is the last minor supporting containerd 1.x; 1.36 requires 2.x. |
| CNI | Cilium 1.20.x, kube-proxy kept | eBPF datapath, arm64 images; kube-proxy stays until you study the replacement deliberately. |
| OS | Ubuntu Server 24.04 LTS arm64 | Standard kubeadm target; kernel 6.8 ships the vxlan and BPF features Cilium needs. |
| Boot disk | USB 3 SSD, not microSD | etcd fsyncs on every write; SD card latency causes leader elections and API timeouts. |

If 4 GB per node gets tight, the fallback is a single control plane on `node01` with two workers: same steps, but skip kube-vip and join nodes 2 and 3 without `--control-plane`. Budget roughly 600–800 MB per node for etcd plus the control-plane pods.

## 3. Prepare the OS (all three nodes)

Flash Ubuntu Server 24.04 LTS (64-bit) onto each SSD with Raspberry Pi Imager, setting hostname (`node01`–`node03`), user and SSH key in the imager's settings. A Pi 4 boots from USB once its bootloader EEPROM is current. Give each node a DHCP reservation on the router so these stay put.

Actual LAN is `192.168.0.0/24` (not `192.168.1.0/24` as originally drafted). Node IPs, DHCP-reserved by MAC on the router and confirmed stable as of 2026-09-26:

| Node | IP | MAC |
| --- | --- | --- |
| node01 | 192.168.0.62 | e4:5f:01:60:7f:29 |
| node02 | 192.168.0.63 | e4:5f:01:60:6e:af |
| node03 | 192.168.0.64 | e4:5f:01:60:81:71 |

**Steps 3–5 are scripted.** `scripts/01-os-prep.sh` is everything in this
section up to the reboot; `scripts/02-runtime-and-tools.sh` is the
post-reboot checks plus steps 4 and 5. Both are idempotent, so re-running on
an already-prepped node is safe. `scripts/run-remote.sh <script> <user@host>`
copies one over and runs it:

```sh
./scripts/run-remote.sh 01-os-prep.sh admin@192.168.0.63   # reboots at the end
# wait for it to come back, then:
./scripts/run-remote.sh 02-runtime-and-tools.sh admin@192.168.0.63
```

They need an interactive terminal — `sudo` on these nodes prompts for a
password, and `requiretty` means piping it in doesn't work. The rest of this
section is what those scripts actually do, kept here because knowing it
matters more than running it.

```bash
sudo apt update && sudo apt full-upgrade -y

# Node name resolution (skip if Pi-hole already serves these records)
cat <<EOF | sudo tee -a /etc/hosts
192.168.0.62 node01
192.168.0.63 node02
192.168.0.64 node03
EOF

# Swap off: kubeadm preflight fails with swap enabled
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
swapon --show   # must print nothing

# Memory cgroup is off by default on Pi kernels; guarded so a rerun doesn't duplicate the flags
grep -q cgroup_memory=1 /boot/firmware/cmdline.txt || \
  sudo sed -i '1 s/$/ cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe -a overlay br_netfilter

# Sysctls
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Longhorn prerequisites (it needs iSCSI; multipathd claims Longhorn's block devices)
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
sudo systemctl disable --now multipathd.socket multipathd 2>/dev/null || true

sudo reboot
```

After the reboot, on each node:

```bash
cat /sys/fs/cgroup/cgroup.controllers        # must include cpuset and memory
modinfo vxlan >/dev/null && echo vxlan ok    # if missing: sudo apt install linux-modules-extra-raspi
timedatectl | grep synchronized              # must say yes: no RTC on a Pi, and every TLS cert depends on the clock
sudo ufw status                              # expect inactive
```

The `vxlan` check matters because Cilium's default tunnel mode needs it. Older Ubuntu raspi kernels shipped it only in `linux-modules-extra-raspi`; 24.04's kernel includes it, but verify rather than assume.

## 4. Install containerd 2.x (all three nodes)

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y containerd.io

containerd --version   # must be 2.x
```

If it reports 1.7, stop and fix that first: Kubernetes 1.36 drops containerd 1.x, so the first `kubeadm upgrade` would strand the node.

Configure the runtime:

```bash
# Docker's package ships a config.toml with the CRI plugin disabled; replace it with the full default
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# systemd cgroup driver, matching kubelet
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n SystemdCgroup /etc/containerd/config.toml   # must show true

sudo systemctl restart containerd
sudo systemctl enable containerd
```

The sed still works on containerd 2.x: its default config (format `version = 4`) keeps `SystemdCgroup = false` under the runc runtime options. If kubelet and containerd disagree on the cgroup driver, pods fail to start with sandbox errors that don't name the real cause.

`kubeadm init` may warn that containerd's `sandbox` (pause) image differs from the one kubeadm expects. It's harmless; to silence it, set `sandbox` in `config.toml` to the pause image from `kubeadm config images list` and restart containerd.

## 5. Install kubeadm, kubelet, kubectl (all three nodes)

```bash
sudo apt install -y apt-transport-https gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet   # crash-loops until kubeadm init/join; that's expected

kubeadm version -o short               # v1.35.x
sudo kubeadm config images pull        # optional: pre-pull so init doesn't time out on slow links
```

The repo path is per minor version, so moving to 1.36 later means changing `v1.35` to `v1.36` in `kubernetes.list` as part of the upgrade.

**Your Mac's kubectl:** Homebrew tracks the newest release (1.37 now), and kubectl is only supported within one minor of the API server. Install a 1.35 or 1.36 binary for this cluster:

```bash
curl -LO "https://dl.k8s.io/release/v1.35.8/bin/darwin/arm64/kubectl"
chmod +x kubectl && mv kubectl ~/bin/kubectl-1.35   # then alias k=kubectl-1.35, or use mise/asdf to pin per directory
```

## 6. Initialize the first control plane (node01)

Pick the API server VIP: an unused LAN IP outside both the DHCP range and the LoadBalancer pool. Router's DHCP pool is confirmed as `192.168.0.33`–`192.168.0.199`, so `192.168.0.200` is used below. `192.168.0.210`–`192.168.0.230` is reserved for the cluster's LoadBalancer IP pool, so it never collides with the VIP.

That pool is served by **MetalLB** in L2 mode. Because kubeadm labels every control-plane node `node.kubernetes.io/exclude-from-external-load-balancers`, and all three nodes here are control-plane, MetalLB's speaker needs `ignoreExcludeLB: true` or it silently answers ARP from no node at all. See [`architecture.md`](architecture.md#loadbalancer-ips-metallb-l2-mode).

**kube-vip static pod.** It has to exist before `kubeadm init`, because init talks to the API server through the VIP.

```bash
export VIP=192.168.0.200
export INTERFACE=eth0          # confirm with: ip -br addr
export KVVERSION=v1.2.4

sudo mkdir -p /etc/kubernetes/manifests
sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest pod \
  --interface $INTERFACE --address $VIP \
  --controlplane --arp --leaderElection \
  | sudo tee /etc/kubernetes/manifests/kube-vip.yaml

# Since kubeadm 1.29, admin.conf has no RBAC binding until init finishes.
# kube-vip needs API access during init, so it bootstraps with super-admin.conf.
sudo sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' \
  /etc/kubernetes/manifests/kube-vip.yaml
```

No `--services` flag: kube-vip handles only the API server VIP. LoadBalancer Services are owned by MetalLB (see the note above).

**kubeadm config file.** A config file instead of flags is what you'd version in git, and it's the only place some settings live. Unlike `kube-vip.yaml`, this file is **not** a static pod manifest and does **not** go in `/etc/kubernetes/manifests/` — it's just an input file for the `kubeadm init` command below, so it can live anywhere convenient, e.g. your home directory on node01 (`~/kubeadm-config.yaml`). Create it with:

```bash
cat <<'EOF' > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.0.62
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.8
controlPlaneEndpoint: "192.168.0.200:6443"
apiServer:
  certSANs:
    - 192.168.0.200
    - k8s-api.lan
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

The single-quoted `'EOF'` stops the shell from expanding anything inside the heredoc — a safe habit even though nothing here needs expanding. `controlPlaneEndpoint` is an IP, not a Pi-hole name, so the API doesn't depend on DNS that may itself run on the cluster. The extra SAN lets you switch to `k8s-api.lan` later without re-issuing certs. Neither subnet may overlap your LAN.

**Init:**

```bash
sudo kubeadm init --config kubeadm-config.yaml --upload-certs | tee kubeadm-init.log

# RBAC exists now: move kube-vip back to the normal kubeconfig (kubelet restarts the static pod)
sudo sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#' \
  /etc/kubernetes/manifests/kube-vip.yaml
```

The log contains two join commands; you need the one with `--control-plane --certificate-key`. The certificate key expires after 2 hours and the token after 24. To regenerate: `sudo kubeadm init phase upload-certs --upload-certs` for a new key, `kubeadm token create --print-join-command` for the rest.

**kubeconfig:**

```bash
# on node01
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config

# on the Mac
scp node01:.kube/config ~/.kube/pi-cluster.yaml
export KUBECONFIG=~/.kube/config:~/.kube/pi-cluster.yaml
```

The server URL is the VIP, so kubectl keeps working when `node01` is down. Never copy `super-admin.conf` off the node: it bypasses RBAC entirely and can't be revoked short of rotating the CA.

The node shows `NotReady` until the CNI is in.

## 7. Install Cilium (from the Mac)

kubeadm installs no CNI: nodes stay `NotReady` and CoreDNS stays `Pending` until one is in. The two sensible options:

- **Cilium**: eBPF-based, ARM64-supported, and lines up with the deep-dive you're already doing in `k8s-networking-the-hard-way`
- **Calico**: simpler, iptables-based, very common in production and on the CKA exam

```bash
brew install helm cilium-cli

helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.20.2 \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false

cilium status --wait
kubectl get nodes    # node01 Ready, coredns Running
```

`ipam.mode=kubernetes` makes Cilium use the per-node pod CIDRs that the controller-manager carves out of `podSubnet`, so the kubeadm config stays the single source of truth. Cilium's default cluster-pool mode would ignore it and allocate from `10.0.0.0/8`.

`kubeProxyReplacement=false` keeps kube-proxy in the datapath for now. Turn it on only after you've studied what it replaces, in line with the manual-first approach.

Once ArgoCD is running (step 10), adopt this release as an Application with the same chart version and values, so the CNI is declared in `control-plane` like everything else.

## 8. Join node02 and node03 as control planes

**Getting the token, hash and certificate key.** The join command needs three values: `--token`, `--discovery-token-ca-cert-hash`, and `--certificate-key`. All three came printed in `kubeadm-init.log` from step 6 — if that file is still around and it's been less than 2 hours since `kubeadm init`, just read it:

```bash
# on node01
grep -A2 "kubeadm join" kubeadm-init.log
```

Copy the block that includes `--control-plane --certificate-key` (there are two join commands in the log; the other one, without those flags, is for plain workers — not used in this all-control-plane setup).

If the log is gone, or the certificate key (2h) or token (24h) has expired, regenerate each piece on node01:

```bash
# on node01

# fresh join token + matching discovery hash, printed as a ready-to-use command
kubeadm token create --print-join-command

# fresh certificate key (separate expiry from the token above)
sudo kubeadm init phase upload-certs --upload-certs
```

`kubeadm token create --print-join-command` gives you the full `kubeadm join <vip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...` line already assembled — you only need to append `--control-plane --certificate-key <key-from-upload-certs>` and `--apiserver-advertise-address <this-node-ip>` to it before running it on node02/node03.

On each node, run the control-plane join:

```bash
sudo kubeadm join 192.168.0.200:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <key> \
  --apiserver-advertise-address <this-node-ip>   # 192.168.0.63 on node02, 192.168.0.64 on node03
```

Join one node at a time and wait until its `etcd-nodeN` pod is `Running` before starting the next. Going from 1 to 2 etcd members raises quorum to 2, so a second member that never finishes syncing takes the whole API down with it.

Then add kube-vip on the joined node so it can hold the VIP when `node01` is gone. Rerun the same `ctr run … manifest pod` command from step 6 on that node. Skip the `super-admin.conf` sed: on a joined control plane, `admin.conf` already has permissions, and `super-admin.conf` only exists on `node01`.

```bash
# on node02 / node03, after the join succeeds
sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest pod \
  --interface $INTERFACE --address $VIP \
  --controlplane --arp --leaderElection \
  | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

Finally, let all three run workloads:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## 9. Verify

```bash
kubectl get nodes -o wide                  # 3 nodes Ready, all with the control-plane role
kubectl get pods -n kube-system -o wide    # etcd, apiserver, controller-manager, scheduler, kube-vip, cilium on every node
kubectl get --raw='/readyz?verbose'        # use this instead of the deprecated `kubectl get cs`
cilium status
```

**etcd membership** (expect 3 `started` members):

```bash
kubectl -n kube-system exec etcd-node01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

**VIP failover**, the reason for the HA setup:

```bash
ip -br addr show eth0    # run on each node; the one listing 192.168.0.200 holds the VIP
# power that node off, then from the Mac:
kubectl get nodes        # still answers; the dead node turns NotReady after ~40 s
```

**Smoke test** that sends real traffic through a Service, CoreDNS and cross-node pod networking:

```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl expose deployment web --port=80
kubectl get pods -l app=web -o wide     # replicas spread across nodes
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://web.default.svc.cluster.local | head -4
kubectl delete deployment,service web
```

**Baseline etcd snapshot** before layering anything on top (also CKA practice). `/var/lib/etcd` is a hostPath, so the file lands on `node01`'s disk:

```bash
kubectl -n kube-system exec etcd-node01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/baseline.db
```

Restoring uses `etcdutl snapshot restore`; the `etcdctl` restore subcommand is gone in etcd 3.6.

## 10. Rebuild the GitOps stack

Order matters because of bootstrap dependencies:

1. Recreate the hand-held Secrets from step 1 (1Password Connect credentials and token). Everything else comes from 1Password through ESO.
2. Install ArgoCD with Helm, then apply the app-of-apps root Application from `control-plane`.
3. Let ArgoCD sync the rest. Make sure CRD-providing apps (cert-manager, ESO, Envoy Gateway) land before the resources that use them. Note: sync-wave annotations on a *manually-synced* Application will stall the root app's whole sync waiting for it to go healthy — that happened with Cilium during this rebuild. Prefer bundling each component's CRs into its own Application (multi-source) over cross-Application wave ordering.
4. Adopt Cilium as an Application (step 7).

Checks specific to this rebuild:

- **LoadBalancer pool vs VIP.** MetalLB's `IPAddressPool` must exclude the kube-vip address. Two things answering ARP for one IP produce intermittent API timeouts that look like network flakiness.
- **ArgoCD controller memory.** The default 512Mi limit OOMKills (exit 137, CrashLoopBackOff) once Cilium, Envoy Gateway and the Prometheus stack are all being diffed — it holds every rendered manifest in memory. 1Gi was needed here. The symptom is misleading: every Application appears stuck mid-sync rather than pointing at the controller.
- **Storage.** Longhorn is *not* what ended up running — `local-path-provisioner` is, as a deliberate stopgap (single small pod, no replication, PVC data pinned to one node). If/when Longhorn does land, run `longhornctl check preflight` first; it catches missing iSCSI or a live multipathd from step 3. Note the Prometheus Operator treats a missing StorageClass as fatal and refuses to create the StatefulSet at all, rather than leaving a pod `Pending` — so "no Prometheus pod exists" is the symptom of a storage problem, not a Prometheus one.
- **Ingress.** Upstream ingress-nginx was retired in March 2026 and gets no further security fixes. You're redeploying anyway, so this is the cheap moment to move to Gateway API, which is also on the CKA curriculum. With `kubeProxyReplacement=false`, Envoy Gateway is the straightforward pick; Cilium's own Gateway API implementation requires kube-proxy replacement enabled.
- **DNS.** Re-point Pi-hole records and the Cloudflare DNS-01 setup if any node or LoadBalancer IP changed.

## 11. Later: upgrade to 1.36

When the exam moves to 1.36, or whenever you want the practice, upgrade one minor at a time, one node at a time:

1. On every node, change `v1.35` to `v1.36` in `/etc/apt/sources.list.d/kubernetes.list` and upgrade only `kubeadm` (unhold, install, re-hold).
2. On `node01`: `sudo kubeadm upgrade plan`, then `sudo kubeadm upgrade apply v1.36.x`.
3. On `node02` and `node03`: `sudo kubeadm upgrade node`.
4. Per node: `kubectl drain`, upgrade `kubelet` and `kubectl`, `sudo systemctl restart kubelet`, `kubectl uncordon`.

containerd is already 2.x from step 4, so nothing blocks the move. Take an etcd snapshot before step 2.

## Sources

- [Kubernetes releases](https://kubernetes.io/releases/): 1.37.0 released 2026-08-26; 1.35 supported until 2027-02-28
- [CKA certification page](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/): exam on v1.35; HA control plane and Gateway API in the curriculum
- [Kubernetes v1.35 Sneak Peek](https://kubernetes.io/blog/2025/11/26/kubernetes-v1-35-sneak-peek/): 1.35 is the last release supporting containerd 1.x
- [Ingress NGINX Retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [kube-vip static pod install](https://kube-vip.io/docs/installation/static/) and [kube-vip issue #684](https://github.com/kube-vip/kube-vip/issues/684): `super-admin.conf` requirement since kubeadm 1.29
- [Launchpad bug #2036747](https://bugs.edge.launchpad.net/bugs/2036747): vxlan moved into the base raspi kernel modules
- Versions checked against upstream git tags on this date: Cilium v1.20.2 (`stable.txt`), containerd v2.4.1, kube-vip v1.2.4. containerd 2.4.1's default config was inspected directly to confirm the `SystemdCgroup` sed.
