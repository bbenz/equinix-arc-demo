#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Join an additional K3s AGENT node in the Equinix cage (same proxy model as
# install-k3s-server.sh).
#
# Usage (as root, on the node):
#   K3S_URL=https://10.80.0.11:6443 K3S_TOKEN=<node-token> \
#   EGRESS_PROXY=http://10.50.1.10:3128 NODE_IP=10.80.0.12 ./install-k3s-agent.sh
# -----------------------------------------------------------------------------
set -euo pipefail

: "${K3S_URL:?Set K3S_URL to https://<server-ip>:6443}"
: "${K3S_TOKEN:?Set K3S_TOKEN to the server node token}"
: "${EGRESS_PROXY:?Set EGRESS_PROXY to terraform/azure output egress_proxy_url}"
: "${NODE_IP:?Set NODE_IP to the cage IP address of this node}"

NODE_CIDRS="${NODE_CIDRS:-10.80.0.0/24}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
K3S_VERSION="${K3S_VERSION:-}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
PRIVATE_ACR="${PRIVATE_ACR:-}"

NO_PROXY_LIST="127.0.0.0/8,localhost,${NODE_CIDRS},${CLUSTER_CIDR},${SERVICE_CIDR},.svc,.cluster.local"
export HTTP_PROXY="$EGRESS_PROXY" HTTPS_PROXY="$EGRESS_PROXY" NO_PROXY="$NO_PROXY_LIST"
export http_proxy="$EGRESS_PROXY" https_proxy="$EGRESS_PROXY" no_proxy="$NO_PROXY_LIST"

if [[ -n "$PRIVATE_ACR" ]]; then
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "https://${PRIVATE_ACR}"
  us-central1-docker.pkg.dev:
    endpoint:
      - "https://${PRIVATE_ACR}"
EOF
fi

curl -sfL https://get.k3s.io | env \
  INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
  ${K3S_VERSION:+INSTALL_K3S_VERSION="$K3S_VERSION"} \
  K3S_URL="$K3S_URL" \
  K3S_TOKEN="$K3S_TOKEN" \
  sh -s - agent --node-ip "$NODE_IP"

echo "Agent installed. Check from the server: k3s kubectl get nodes -o wide"
