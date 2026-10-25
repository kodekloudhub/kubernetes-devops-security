#!/usr/bin/env bash
#
# install-script.sh
# Ubuntu 22.04/24.04/26.04
# Installs:
#   - Docker Engine + Compose plugin (for Jenkins/builds)
#   - containerd configuration for Kubernetes (Kubernetes does not use Docker directly)
#   - Kubernetes kubeadm/kubelet/kubectl
#   - Single-node Kubernetes control-plane
#   - Calico CNI
#   - OpenJDK 21
#   - Maven
#   - Jenkins LTS
#
# IMPORTANT:
#   This script is intended for Ubuntu 22.04/24.04/26.04.
#   Do NOT run it on the Ubuntu 18.04 image from the old ARM template.
#
# Run as root:
#   sudo bash install-script.sh
#

set -Eeuo pipefail

K8S_MINOR="v1.37"
POD_CIDR="192.168.0.0/16"
CALICO_VERSION="v3.33.0"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

trap 'echo "ERROR: installation failed at line $LINENO. Command: $BASH_COMMAND" >&2' ERR

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root: sudo bash install-script.sh"

source /etc/os-release

[[ "${ID}" == "ubuntu" ]] || die "This script supports Ubuntu only. Detected: ${ID:-unknown}"

case "${VERSION_ID}" in
    22.04|24.04|26.04)
        ;;
    *)
        die "Unsupported Ubuntu version: ${VERSION_ID}. Use Ubuntu 22.04, 24.04, or 26.04. Your old Ubuntu 18.04 image is not supported by this script."
        ;;
esac

export DEBIAN_FRONTEND=noninteractive

# Remove obsolete repositories from previous installations.
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/sources.list.d/jenkins.list

# Remove old Jenkins signing keys.
rm -f /etc/apt/keyrings/jenkins-keyring.asc
rm -f /usr/share/keyrings/jenkins-keyring.asc

log "SYSTEM INFORMATION"
echo "Ubuntu: ${PRETTY_NAME}"
echo "Kernel: $(uname -r)"
echo "Architecture: $(dpkg --print-architecture)"
echo "CPU: $(nproc)"
echo "Memory:"
free -h
echo

log "PREPARE APT"
apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    jq \
    vim \
    build-essential \
    python3-pip \
    wget \
    unzip \
    git \
    dmidecode \
    fontconfig

install -m 0755 -d /etc/apt/keyrings

log "DISABLE SWAP FOR KUBERNETES"
swapoff -a || true
sed -i.bak '/\sswap\s/ s/^/#/' /etc/fstab || true

log "INSTALL DOCKER ENGINE"
# Remove conflicting distribution Docker packages if present.
apt-get remove -y \
    docker.io \
    docker-compose \
    docker-compose-v2 \
    docker-doc \
    docker-buildx \
    podman-docker \
    containerd \
    runc 2>/dev/null || true

rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/sources.list.d/docker.sources
rm -f /etc/apt/keyrings/docker.asc

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "storage-driver": "overlay2"
}
EOF

systemctl daemon-reload
systemctl enable --now docker

# Docker's bundled containerd is used as Kubernetes' CRI runtime.
log "CONFIGURE CONTAINERD FOR KUBERNETES"

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

# Make containerd use systemd cgroups, which matches kubeadm/Kubernetes guidance.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

log "CONFIGURE KERNEL MODULES AND SYSCTL"

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

log "INSTALL KUBERNETES ${K8S_MINOR}"

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF

apt-get update

apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

log "VERIFY KUBERNETES PACKAGES"
kubeadm version
kubectl version --client
kubelet --version
crictl --version 2>/dev/null || true

log "INITIALIZE SINGLE-NODE KUBERNETES CLUSTER"

# If a previous failed kubeadm installation exists, reset it first.
if [[ -f /etc/kubernetes/admin.conf ]] || [[ -f /etc/kubernetes/kubelet.conf ]]; then
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true
fi

rm -rf /root/.kube

kubeadm init \
    --pod-network-cidr="${POD_CIDR}" \
    --cri-socket=unix:///run/containerd/containerd.sock

log "CONFIGURE KUBECTL FOR ROOT"

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf

log "INSTALL CALICO CNI ${CALICO_VERSION}"

# Calico 3.33 is tested with Kubernetes 1.35, 1.36 and 1.37.
kubectl create -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v3_projectcalico_org.yaml" || true

kubectl create -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" || true

log "ALLOW PODS TO RUN ON THIS SINGLE NODE"

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/master:NoSchedule- 2>/dev/null || true
kubectl taint nodes "${NODE_NAME}" node.kubernetes.io/not-ready:NoSchedule- 2>/dev/null || true

log "INSTALL JC"
python3 -m pip install --break-system-packages jc

log "VM UUID"
if command -v dmidecode >/dev/null 2>&1; then
    UUID="$(dmidecode -s system-uuid 2>/dev/null || true)"
    echo "System UUID: ${UUID:-not available}"
fi

log "INSTALL JAVA 21"
apt-get install -y openjdk-21-jdk

java -version

log "INSTALL MAVEN"
apt-get install -y maven

mvn -v

log "INSTALL JENKINS LTS"

# Jenkins changed its Linux repository signing key in 2026.
rm -f /etc/apt/sources.list.d/jenkins.list
rm -f /usr/share/keyrings/jenkins-keyring.asc
rm -f /etc/apt/keyrings/jenkins-keyring.asc

install -m 0755 -d /etc/apt/keyrings

wget -O /etc/apt/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

chmod 644 /etc/apt/keyrings/jenkins-keyring.asc

cat > /etc/apt/sources.list.d/jenkins.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/
EOF

apt-get update
apt-get install -y jenkins

log "CONFIGURE JENKINS + DOCKER"

# Allow Jenkins to use Docker without sudo.
usermod -aG docker jenkins

systemctl daemon-reload
systemctl enable --now jenkins

# Restart after group membership is created.
systemctl restart jenkins

log "WAIT FOR JENKINS"
sleep 10

log "INSTALLATION STATUS"

echo
echo "Docker:"
systemctl --no-pager --full status docker | head -20 || true

echo
echo "Containerd:"
systemctl --no-pager --full status containerd | head -20 || true

echo
echo "Kubelet:"
systemctl --no-pager --full status kubelet | head -20 || true

echo
echo "Jenkins:"
systemctl --no-pager --full status jenkins | head -20 || true

echo
echo "Kubernetes nodes:"
kubectl get nodes -o wide || true

echo
echo "Kubernetes pods:"
kubectl get pods -A || true

echo
echo "Docker version:"
docker --version

echo
echo "Docker Compose:"
docker compose version

echo
echo "Java:"
java -version

echo
echo "Maven:"
mvn -v

echo
echo "Jenkins initial admin password:"
if [[ -f /var/lib/jenkins/secrets/initialAdminPassword ]]; then
    cat /var/lib/jenkins/secrets/initialAdminPassword
else
    echo "Password file not available yet. Check: sudo journalctl -u jenkins"
fi

echo
echo "============================================================"
echo "INSTALLATION COMPLETED"
echo "============================================================"
echo
echo "Jenkins URL: http://<VM-PUBLIC-IP>:8080"
echo
echo "Useful commands:"
echo "  docker ps"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -A"
echo "  sudo systemctl status jenkins"
echo "  sudo journalctl -u jenkins -f"
echo
echo "NOTE: Log out/in before using Docker as a non-root user."
