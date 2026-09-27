#!/usr/bin/env bash
# Steps 3 (post-reboot checks), 4 (containerd) and 5 (kubeadm/kubelet/kubectl).
# Run on each node AFTER it has rebooted from 01-os-prep.sh.
set -euo pipefail

echo "==> Post-reboot checks (informational only)"
grep -qE 'cpuset|memory' /sys/fs/cgroup/cgroup.controllers \
  && echo "cgroup controllers ok: $(cat /sys/fs/cgroup/cgroup.controllers)" \
  || echo "WARNING: cpuset/memory missing from cgroup.controllers"
modinfo vxlan >/dev/null 2>&1 && echo "vxlan ok" || echo "WARNING: vxlan module missing (sudo apt install linux-modules-extra-raspi)"
timedatectl | grep -q "synchronized: yes" && echo "clock synchronized" || echo "WARNING: clock not synchronized yet"
sudo ufw status | grep -q inactive && echo "ufw inactive (expected)" || echo "NOTE: ufw is active, check it's not blocking cluster ports"

echo "==> Step 4: install containerd 2.x"
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y containerd.io

containerd --version   # must be 2.x

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n SystemdCgroup /etc/containerd/config.toml   # must show true

sudo systemctl restart containerd
sudo systemctl enable containerd

echo "==> Step 5: install kubeadm, kubelet, kubectl"
sudo apt install -y apt-transport-https gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | sudo gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet   # crash-loops until kubeadm init/join; that's expected

kubeadm version -o short               # v1.35.x
sudo kubeadm config images pull        # optional: pre-pull so init doesn't time out on slow links

echo "==> Node ready for step 6 (node01) or step 8 (node02/3 join)"
