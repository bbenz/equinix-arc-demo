#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Install the FIRST K3s server node in the Equinix cage.
#
# The cage has NO internet egress. Everything this node needs leaves the cage
# only over ExpressRoute, through the Squid explicit proxy in the Azure hub VNet
# (terraform/azure output `egress_proxy_url`):
#   - this installer + the K3s binary (get.k3s.io, github.com)
#   - container images (Docker Hub, Artifact Registry - or a private ACR)
#   - Azure Arc agents (Arc gateway) and the Fleet member agent
#
# Usage (as root, on the node):
#   EGRESS_PROXY=http://10.50.1.10:3128 NODE_IP=10.80.0.11 ./install-k3s-server.sh
#
# Optional:
#   NODE_CIDRS=10.80.0.0/24        cage subnet(s), comma-separated (kept off the proxy)
#   K3S_CHANNEL=stable             or e.g. v1.34
#   K3S_VERSION=v1.34.x+k3s1       exact pin (wins over K3S_CHANNEL)
#   PRIVATE_ACR=<name>.azurecr.io  mirror docker.io + Artifact Registry through
#                                  the private ACR (enable_private_acr = true)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${EGRESS_PROXY:?Set EGRESS_PROXY to terraform/azure output egress_proxy_url, e.g. http://10.50.1.10:3128}"
: "${NODE_IP:?Set NODE_IP to the cage IP address of this node}"

NODE_CIDRS="${NODE_CIDRS:-10.80.0.0/24}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
K3S_VERSION="${K3S_VERSION:-}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
TLS_SAN="${TLS_SAN:-$NODE_IP}"
PRIVATE_ACR="${PRIVATE_ACR:-}"

NO_PROXY_LIST="127.0.0.0/8,localhost,${NODE_CIDRS},${CLUSTER_CIDR},${SERVICE_CIDR},.svc,.cluster.local"

# The K3s installer copies these into /etc/systemd/system/k3s.service.env, so
# K3s, the kubelet and the embedded containerd all use the proxy afterwards.
export HTTP_PROXY="$EGRESS_PROXY" HTTPS_PROXY="$EGRESS_PROXY" NO_PROXY="$NO_PROXY_LIST"
export http_proxy="$EGRESS_PROXY" https_proxy="$EGRESS_PROXY" no_proxy="$NO_PROXY_LIST"

echo "==> Checking the ExpressRoute path to the egress proxy (${EGRESS_PROXY})"
curl -sS -o /dev/null -w "    management.azure.com via proxy -> HTTP %{http_code}\n" \
  --max-time 15 "https://management.azure.com/metadata/endpoints?api-version=2023-11-01"

if [[ -n "$PRIVATE_ACR" ]]; then
  echo "==> Configuring containerd mirrors -> ${PRIVATE_ACR} (private endpoint, reached through the proxy)"
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/registries.yaml <<EOF
# Images were imported into ${PRIVATE_ACR} with their upstream repository paths
# (scripts/lib/Import-ImagesToAcr.ps1). Anything missing falls back to the
# upstream registry through the proxy.
mirrors:
  docker.io:
    endpoint:
      - "https://${PRIVATE_ACR}"
  us-central1-docker.pkg.dev:
    endpoint:
      - "https://${PRIVATE_ACR}"
EOF
fi

echo "==> Installing K3s server (channel=${K3S_CHANNEL}${K3S_VERSION:+, version=${K3S_VERSION}})"
# - Traefik disabled: port 80 must be free for the frontend-external Service
#   (K3s ServiceLB publishes LoadBalancer Services on the node IPs).
# - --cluster-init: embedded etcd, so more servers can join later for HA.
curl -sfL https://get.k3s.io | env \
  INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
  ${K3S_VERSION:+INSTALL_K3S_VERSION="$K3S_VERSION"} \
  sh -s - server \
    --cluster-init \
    --disable traefik \
    --write-kubeconfig-mode 0644 \
    --node-ip "$NODE_IP" \
    --tls-san "$TLS_SAN" \
    --cluster-cidr "$CLUSTER_CIDR" \
    --service-cidr "$SERVICE_CIDR"

echo "==> Waiting for the node to become Ready (up to 5 minutes)"
ready=0
for _ in $(seq 1 60); do
  if k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ { found = 1 } END { exit !found }'; then
    ready=1
    break
  fi
  sleep 5
done
k3s kubectl get nodes -o wide || true
if [[ "$ready" -ne 1 ]]; then
  echo "ERROR: the K3s node did not become Ready. Check: journalctl -u k3s -n 100 --no-pager" >&2
  echo "       (image pulls go through ${EGRESS_PROXY} - run ./verify-egress.sh to test that path)" >&2
  exit 1
fi

cat <<EOF

K3s server is up. Next steps:
  1. Join agents:   K3S_URL=https://${NODE_IP}:6443 K3S_TOKEN=\$(sudo cat /var/lib/rancher/k3s/server/node-token)
                    EGRESS_PROXY=${EGRESS_PROXY} NODE_IP=<agent-ip> ./install-k3s-agent.sh
  2. Kubeconfig for the operator workstation (must reach ${NODE_IP}:6443):
       sudo sed "s/127.0.0.1/${NODE_IP}/" /etc/rancher/k3s/k3s.yaml > equinix-demo.kubeconfig
     then on the workstation (see docs/EQUINIX-CLUSTER.md):
       KUBECONFIG=~/.kube/config:equinix-demo.kubeconfig kubectl config view --flatten > merged && mv merged ~/.kube/config
       kubectl config rename-context default equinix-demo
  3. Verify egress allow/deny:  EGRESS_PROXY=${EGRESS_PROXY} ./verify-egress.sh
EOF
