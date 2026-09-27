#!/usr/bin/env bash
# Step 3: Prepare the OS. Run on each node. Ends in a reboot.
set -euo pipefail

sudo apt update && sudo apt full-upgrade -y

# Node name resolution (skip if Pi-hole already serves these records)
if ! grep -q "node01" /etc/hosts; then
  cat <<EOF | sudo tee -a /etc/hosts
192.168.0.62 node01
192.168.0.63 node02
192.168.0.64 node03
EOF
else
  echo "==> /etc/hosts already has node entries, skipping"
fi

# Swap off: kubeadm preflight fails with swap enabled
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^[^#]/#&/' /etc/fstab
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

echo "==> OS prep done, rebooting now"
sudo reboot
