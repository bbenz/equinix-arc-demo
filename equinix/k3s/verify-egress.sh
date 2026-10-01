#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Prove the Equinix node's egress posture (great for rehearsal, and a nice
# 20-second on-stage moment):
#   1. The Azure egress proxy is reachable over ExpressRoute (route + TCP).
#   2. Allowed Azure endpoints work THROUGH the proxy.
#   3. Anything not on the allowlist is refused by the proxy (HTTP 403).
#   4. There is no direct internet path from the cage (a direct path FAILS the
#      check - set ALLOW_DIRECT_EGRESS=1 to downgrade it to a warning, e.g. in
#      a lab that still has a temporary internet uplink).
#
# Usage: EGRESS_PROXY=http://10.50.1.10:3128 ./verify-egress.sh
# -----------------------------------------------------------------------------
set -uo pipefail
: "${EGRESS_PROXY:?Set EGRESS_PROXY, e.g. http://10.50.1.10:3128}"
ALLOW_DIRECT_EGRESS="${ALLOW_DIRECT_EGRESS:-0}"

proxy_host="$(echo "$EGRESS_PROXY" | sed -E 's#^https?://##; s#:[0-9]+/?$##')"
proxy_port="$(echo "$EGRESS_PROXY" | sed -E 's#^.*:([0-9]+)/?$#\1#')"
fail=0

echo "== 1. Route to the Azure hub (should be via your ExpressRoute edge router)"
ip route get "$proxy_host" || fail=1
if timeout 5 bash -c "</dev/tcp/${proxy_host}/${proxy_port}" 2>/dev/null; then
  echo "   TCP ${proxy_host}:${proxy_port} reachable"
else
  echo "   TCP ${proxy_host}:${proxy_port} NOT reachable - check BGP / private peering"; fail=1
fi

check() { # url expected-code-prefix label
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -x "$EGRESS_PROXY" "$1" 2>/dev/null || true)"
  if [[ "$code" == $2* ]]; then echo "   OK   $3 -> $code"; else echo "   FAIL $3 -> $code (expected $2xx)"; fail=1; fi
}

echo "== 2. Allowed endpoints through the proxy"
check "https://management.azure.com/metadata/endpoints?api-version=2023-11-01" "2" "management.azure.com"
check "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" "2" "login.microsoftonline.com"
check "https://mcr.microsoft.com/v2/" "2" "mcr.microsoft.com"

echo "== 3. Everything else is denied by the proxy allowlist"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -x "$EGRESS_PROXY" https://example.com/ 2>/dev/null || true)"
if [[ "$code" == "403" || "$code" == "000" ]]; then echo "   OK   example.com blocked ($code)"; else echo "   FAIL example.com returned $code"; fail=1; fi

echo "== 4. No direct internet path (expected to time out)"
if curl -sS -o /dev/null --max-time 5 --noproxy '*' https://example.com/ 2>/dev/null; then
  if [[ "$ALLOW_DIRECT_EGRESS" == "1" ]]; then
    echo "   WARN direct internet egress works (allowed by ALLOW_DIRECT_EGRESS=1) - 'only over ExpressRoute' is not true for this node"
  else
    echo "   FAIL direct internet egress works - the demo claim 'only over ExpressRoute' is not true for this node"; fail=1
  fi
else
  echo "   OK   no direct egress"
fi

exit $fail
